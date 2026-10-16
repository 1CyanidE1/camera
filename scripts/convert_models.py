import os
import sys
import traceback

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
from PIL import Image

work, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)


def block(i, o, norm):
    layers = [nn.Conv2d(i, o, 3, stride=2, padding=1), nn.LeakyReLU(0.2)]
    if norm:
        layers.append(nn.InstanceNorm2d(o, affine=True))
    return layers


class Classifier(nn.Module):
    def __init__(self):
        super().__init__()
        self.model = nn.Sequential(
            nn.Upsample(size=(256, 256), mode='bilinear'),
            nn.Conv2d(3, 16, 3, stride=2, padding=1),
            nn.LeakyReLU(0.2),
            nn.InstanceNorm2d(16, affine=True),
            *block(16, 32, True),
            *block(32, 64, True),
            *block(64, 128, True),
            *block(128, 128, False),
            nn.Dropout(p=0.5),
            nn.Conv2d(128, 3, 8, padding=0),
        )

    def forward(self, x):
        return self.model(x)


class Head(nn.Module):
    def __init__(self, classifier):
        super().__init__()
        self.body = nn.Sequential(*list(classifier.model.children())[1:])

    def forward(self, x):
        return self.body(x).reshape(1, 3)


def convert_color():
    print('stage: load classifier', flush=True)
    classifier = Classifier()
    state = torch.load(os.path.join(work, 'classifier.pth'), map_location='cpu', weights_only=False)
    classifier.load_state_dict(state, strict=True)
    classifier.eval()
    head = Head(classifier).eval()

    print('stage: trace', flush=True)
    example = torch.rand(1, 3, 256, 256)
    traced = torch.jit.trace(head, example)
    print('stage: convert', flush=True)
    model = ct.convert(
        traced,
        inputs=[ct.ImageType(name='image', shape=(1, 3, 256, 256), scale=1 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name='weights')],
        minimum_deployment_target=ct.target.iOS17,
        convert_to='mlprogram',
        compute_precision=ct.precision.FLOAT32,
    )
    model.short_description = 'Image-Adaptive 3D LUT classifier (HuiZeng, Apache-2.0), sRGB paired'
    path = os.path.join(out, 'NeuralLUT.mlpackage')
    model.save(path)

    print('stage: luts', flush=True)
    luts = torch.load(os.path.join(work, 'LUTs.pth'), map_location='cpu', weights_only=False)
    print('LUT keys:', list(luts.keys()), [list(luts[k].keys()) for k in luts])
    basis = np.stack([luts[str(i)]['LUT'].detach().numpy() for i in range(3)]).astype(np.float32)
    assert basis.shape == (3, 3, 33, 33, 33), basis.shape

    ramp = np.linspace(0, 1, 33)

    def axis_for(channel):
        cube = basis[0, channel]
        scores = []
        for axis in range(3):
            profile = cube.mean(axis=tuple(a for a in range(3) if a != axis))
            scores.append(np.corrcoef(profile, ramp)[0, 1])
        return int(np.argmax(scores)), scores

    red_axis, red_scores = axis_for(0)
    blue_axis, blue_scores = axis_for(2)
    print('red axis', red_axis, red_scores, 'blue axis', blue_axis, blue_scores)
    assert red_axis != blue_axis, (red_axis, blue_axis)
    green_axis = 3 - red_axis - blue_axis
    order = (0, 1, 2 + blue_axis, 2 + green_axis, 2 + red_axis)
    basis = np.ascontiguousarray(np.transpose(basis, order))
    identity_error = np.abs(basis[0, 0] - ramp[None, None, :]).mean()
    print('LUT0 red channel vs identity ramp (r fastest):', identity_error)
    basis.astype('<f4').tofile(os.path.join(out, 'LUTBasis.bin'))

    print('stage: verify', flush=True)
    rng = np.random.default_rng(0)
    for trial in range(3):
        pixels = (rng.random((256, 256, 3)) * 255).astype(np.uint8)
        if trial == 0:
            pixels = np.tile(np.linspace(0, 255, 256, dtype=np.uint8)[None, :, None], (256, 1, 3))
        tensor = torch.from_numpy(pixels.astype(np.float32) / 255.0).permute(2, 0, 1)[None]
        with torch.no_grad():
            reference = head(tensor).numpy().ravel()
        if sys.platform == 'darwin':
            predicted = np.array(model.predict({'image': Image.fromarray(pixels)})['weights']).ravel()
            print('trial', trial, 'torch', reference, 'coreml', predicted)
            assert np.allclose(reference, predicted, atol=2e-2), (reference, predicted)
        else:
            print('trial', trial, 'torch', reference)


if __name__ == '__main__':
    try:
        convert_color()
    except Exception:
        traceback.print_exc(file=sys.stdout)
        sys.stdout.flush()
        sys.exit(1)
    print('done')
