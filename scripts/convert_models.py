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
        scores = [float(np.abs(np.diff(cube, axis=axis)).mean()) for axis in range(3)]
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


def annotate(title, text):
    body = text.replace('%', '%25').replace('\r', '').replace('\n', '%0A').replace('::', ': :')
    print('::warning title=' + title + '::' + body, flush=True)


class MobileBase(nn.Module):
    def __init__(self):
        super().__init__()
        from mobilenetv2 import MobileNetV2
        model = MobileNetV2(width_mult=1.0)
        self.feature3 = nn.Sequential(model.features[:7])
        self.feature4 = nn.Sequential(model.features[7:14])
        self.feature5 = nn.Sequential(model.features[14:])

    def forward(self, x):
        f3 = self.feature3(x)
        f4 = self.feature4(f3)
        f5 = self.feature5(f4)
        return f3, f4, f5


def fc_layers(reddim, alignsize):
    conv1 = nn.Sequential(nn.Conv2d(reddim, 768, kernel_size=alignsize, padding=0), nn.BatchNorm2d(768), nn.ReLU(inplace=True))
    conv2 = nn.Sequential(nn.Conv2d(768, 128, kernel_size=1), nn.BatchNorm2d(128), nn.ReLU(inplace=True))
    dropout = nn.Dropout(p=0.5)
    conv3 = nn.Conv2d(128, 1, kernel_size=1)
    return nn.Sequential(conv1, conv2, dropout, conv3)


class GAIC(nn.Module):
    def __init__(self, alignsize=9, reddim=8):
        super().__init__()
        self.Feat_ext = MobileBase()
        self.DimRed = nn.Conv2d(448, reddim, kernel_size=1, padding=0)
        self.downsample2 = nn.UpsamplingBilinear2d(scale_factor=1.0 / 2.0)
        self.upsample2 = nn.UpsamplingBilinear2d(scale_factor=2.0)
        self.FC_layers = fc_layers(reddim * 2, alignsize)


class Backbone(nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net
        self.register_buffer('mean', torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer('std', torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

    def forward(self, x):
        x = (x - self.mean) / self.std
        f3, f4, f5 = self.net.Feat_ext(x)
        cat = torch.cat((self.net.downsample2(f3), f4, 0.5 * self.net.upsample2(f5)), 1)
        return self.net.DimRed(cat)


def roi_align(feat, box, scale=1.0 / 16, size=10):
    c, hh, ww = feat.shape
    sw, sh, ew, eh = [np.float32(v * scale) for v in box]
    rw = max(ew - sw + 1.0, 0.0)
    rh = max(eh - sh + 1.0, 0.0)
    bh = np.float32(rh / (size - 1.0))
    bw = np.float32(rw / (size - 1.0))
    out = np.zeros((c, size, size), np.float32)
    for ph in range(size):
        for pw in range(size):
            h = np.float32(ph) * bh + sh
            w = np.float32(pw) * bw + sw
            hs = int(min(np.floor(h), hh - 2))
            ws = int(min(np.floor(w), ww - 2))
            if h < 0 or h >= hh or w < 0 or w >= ww:
                continue
            hr = h - hs
            wr = w - ws
            out[:, ph, pw] = (feat[:, hs, ws] * (1 - hr) * (1 - wr) + feat[:, hs, ws + 1] * (1 - hr) * wr
                              + feat[:, hs + 1, ws] * hr * (1 - wr) + feat[:, hs + 1, ws + 1] * hr * wr)
    return out


def rod_align(feat, box, scale=1.0 / 16, size=10):
    c, hh, ww = feat.shape
    sw, sh, ew, eh = [np.float32(v * scale) for v in box]
    bh = np.float32((hh - 1.001) / (size - 1.0))
    bw = np.float32((ww - 1.001) / (size - 1.0))
    out = np.zeros((c, size, size), np.float32)
    for ph in range(size):
        for pw in range(size):
            h = np.float32(ph) * bh
            w = np.float32(pw) * bw
            hs = int(min(np.floor(h), hh - 2))
            ws = int(min(np.floor(w), ww - 2))
            if sh <= h <= eh and sw <= w <= ew:
                continue
            hr = h - hs
            wr = w - ws
            out[:, ph, pw] = (feat[:, hs, ws] * (1 - hr) * (1 - wr) + feat[:, hs, ws + 1] * (1 - hr) * wr
                              + feat[:, hs + 1, ws] * hr * (1 - wr) + feat[:, hs + 1, ws + 1] * hr * wr)
    return out


def avg_pool2(x):
    return 0.25 * (x[:, :-1, :-1] + x[:, 1:, :-1] + x[:, :-1, 1:] + x[:, 1:, 1:])


def aligned_features(feat, box):
    return np.concatenate([avg_pool2(roi_align(feat, box)), avg_pool2(rod_align(feat, box))], 0)


def gaic_boxes(w, h):
    bins = 12.0
    sh, sw = h / bins, w / bins
    boxes = []
    for x1 in range(4):
        for y1 in range(4):
            for x2 in range(8, 12):
                for y2 in range(8, 12):
                    if (x2 - x1) * (y2 - y1) > 0.4999 * bins * bins and 0.5 < (y2 - y1) * sw / (x2 - x1) / sh < 2.0:
                        boxes.append((sw * (0.5 + y1), sh * (0.5 + x1), sw * (0.5 + y2), sh * (0.5 + x2)))
    return boxes


def convert_crop():
    print('stage: gaic load', flush=True)
    sys.path.insert(0, os.path.join(work, 'gaic'))
    net = GAIC()
    state = torch.load(os.path.join(work, 'gaic.pth'), map_location='cpu', weights_only=False)
    state = {k[7:] if k.startswith('module.') else k: v for k, v in state.items()}
    result = net.load_state_dict(state, strict=False)
    print('missing', result.missing_keys, 'unexpected', result.unexpected_keys, flush=True)
    assert not result.missing_keys and not result.unexpected_keys
    net.eval()
    backbone = Backbone(net).eval()

    print('stage: gaic trace', flush=True)
    example = torch.rand(1, 3, 352, 256)
    traced = torch.jit.trace(backbone, example)
    print('stage: gaic convert', flush=True)
    shapes = ct.EnumeratedShapes(shapes=[[1, 3, 352, 256], [1, 3, 256, 352]], default=[1, 3, 352, 256])
    model = ct.convert(
        traced,
        inputs=[ct.ImageType(name='image', shape=shapes, scale=1 / 256.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name='features')],
        minimum_deployment_target=ct.target.iOS17,
        convert_to='mlprogram',
        compute_precision=ct.precision.FLOAT32,
    )
    model.short_description = 'GAIC MobileNetV2 multi-scale backbone (Zeng et al., MIT)'
    model.save(os.path.join(out, 'GAICBackbone.mlpackage'))

    print('stage: gaic head', flush=True)

    def fold(conv, bn):
        w = conv.weight.detach().numpy().reshape(conv.out_channels, -1)
        b = conv.bias.detach().numpy()
        k = bn.weight.detach().numpy() / np.sqrt(bn.running_var.detach().numpy() + bn.eps)
        return w * k[:, None], (b - bn.running_mean.detach().numpy()) * k + bn.bias.detach().numpy()

    w1, b1 = fold(net.FC_layers[0][0], net.FC_layers[0][1])
    w2, b2 = fold(net.FC_layers[1][0], net.FC_layers[1][1])
    w3 = net.FC_layers[3].weight.detach().numpy().reshape(1, -1)
    b3 = net.FC_layers[3].bias.detach().numpy()
    print('head shapes', w1.shape, w2.shape, w3.shape, flush=True)
    assert w1.shape == (768, 1296) and w2.shape == (128, 768) and w3.shape == (1, 128)
    blob = np.concatenate([w1.ravel(), b1, w2.ravel(), b2, w3.ravel(), b3]).astype('<f4')
    blob.tofile(os.path.join(out, 'GAICHead.bin'))

    def head(x):
        h = np.maximum(w1 @ x + b1, 0)
        h = np.maximum(w2 @ h + b2, 0)
        return float((w3 @ h + b3)[0])

    print('stage: gaic verify', flush=True)
    rng = np.random.default_rng(1)
    pixels = (rng.random((352, 256, 3)) * 255).astype(np.uint8)
    pixels[100:250, 60:200] = [220, 60, 40]
    tensor = torch.from_numpy(pixels.astype(np.float32) / 256.0).permute(2, 0, 1)[None]
    with torch.no_grad():
        feat = backbone(tensor)[0].numpy()
    print('feature map', feat.shape, flush=True)
    boxes = gaic_boxes(256, 352)
    for box in boxes[:6]:
        x = aligned_features(feat, box)
        with torch.no_grad():
            reference = float(net.FC_layers(torch.from_numpy(x[None]))[0, 0, 0, 0])
        mine = head(x.ravel())
        print('box', [round(v, 1) for v in box], 'torch', reference, 'folded', mine, flush=True)
        assert abs(reference - mine) < 1e-3 * max(1.0, abs(reference))
    if sys.platform == 'darwin':
        predicted = np.array(model.predict({'image': Image.fromarray(pixels)})['features'])[0]
        error = np.abs(predicted - feat).max() / (np.abs(feat).max() + 1e-6)
        print('coreml backbone relative error', error, flush=True)
        assert error < 0.05


if __name__ == '__main__':
    try:
        convert_color()
    except Exception:
        traceback.print_exc(file=sys.stdout)
        sys.stdout.flush()
        sys.exit(1)
    try:
        convert_crop()
    except Exception:
        text = traceback.format_exc()
        print(text, flush=True)
        annotate('GAIC conversion failed', text[-3000:])
    print('done')
