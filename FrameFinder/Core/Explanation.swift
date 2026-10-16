import Foundation

struct ShotReason: Codable, Equatable, Hashable {
    var symbol: String
    var text: String
    var good: Bool
}

enum Explainer {
    static func reasons(for b: Breakdown, wholeValue: Double, aesthetic: Double?, neural: Double? = nil) -> [ShotReason] {
        var good: [ShotReason] = []
        var bad: [ShotReason] = []

        let gain = wholeValue > 0 ? b.value / wholeValue : 1
        if b.area > 0.93 {
            good.append(ShotReason(symbol: "checkmark.seal", text: "Весь кадр уже хорош — обрезать нечего", good: true))
        } else if gain > 1.05 {
            let percent = Int(((gain - 1) * 100).rounded())
            good.append(ShotReason(symbol: "chart.line.uptrend.xyaxis",
                                   text: "Композиция на \(percent)% сильнее, чем весь кадр целиком", good: true))
        }

        if b.placementQuality > 0.55 {
            if b.placement == .center {
                good.append(ShotReason(symbol: "plus.viewfinder", text: "Главное ровно по центру — симметричная композиция", good: true))
            } else {
                good.append(ShotReason(symbol: "squareshape.split.3x3", text: "Главное стоит на пересечении линий третей", good: true))
            }
        } else {
            bad.append(ShotReason(symbol: "move.3d", text: "Главное не на третях — компромисс ради остального", good: false))
        }

        if b.area <= 0.93 {
            let kept = Int((b.coverage * 100).rounded())
            let cut = Int(((1 - b.area) * 100).rounded())
            if b.coverage >= 0.75 {
                good.append(ShotReason(symbol: "scissors",
                                       text: "Отрезано \(cut)% площади, а интересного сохранено \(kept)%", good: true))
            } else {
                bad.append(ShotReason(symbol: "scissors", text: "В кадр попало только \(kept)% интересного", good: false))
            }
        }

        if b.edgeClear > 0.85 {
            good.append(ShotReason(symbol: "rectangle.dashed", text: "Ничего важного не упирается в края", good: true))
        } else if b.edgeClear < 0.6 {
            bad.append(ShotReason(symbol: "rectangle.dashed", text: "У краёв есть детали — рамка их задевает", good: false))
        }

        if b.facesCut > 0 {
            bad.append(ShotReason(symbol: "person.crop.circle.badge.exclamationmark", text: "Лицо задето краем кадра", good: false))
        } else if b.facesWhole > 0 {
            let text = b.facesWhole == 1 ? "Лицо целиком в кадре" : "Все лица (\(b.facesWhole)) целиком в кадре"
            good.append(ShotReason(symbol: "face.smiling", text: text, good: true))
            if b.eyeLineOK == true {
                good.append(ShotReason(symbol: "eye", text: "Глаза около верхней трети кадра", good: true))
            }
            if b.headroomOK == false {
                bad.append(ShotReason(symbol: "arrow.up.to.line", text: "Мало места над головой", good: false))
            }
        }

        if b.subjectsCut > 0 {
            bad.append(ShotReason(symbol: "scissors.badge.ellipsis", text: "Объект частично обрезан", good: false))
        } else if b.subjectsWhole > 0 && b.facesWhole == 0 {
            good.append(ShotReason(symbol: "cube", text: "Объект целиком, без обрезки", good: true))
        }

        if b.bodiesCut > 0 {
            bad.append(ShotReason(symbol: "figure.stand", text: "Человек обрезан по фигуре", good: false))
        }

        if b.area < 0.3 {
            bad.append(ShotReason(symbol: "arrow.down.right.and.arrow.up.left",
                                  text: "Кадр тесный — при обрезке теряется часть качества", good: false))
        }

        if let aesthetic {
            let score = String(format: "%.1f", aesthetic * 10)
            if aesthetic >= 0.55 {
                good.append(ShotReason(symbol: "sparkles", text: "Эстетика по оценке Apple: \(score) из 10", good: true))
            } else {
                bad.append(ShotReason(symbol: "sparkles", text: "Эстетика по оценке Apple невысокая: \(score) из 10", good: false))
            }
        }

        if let neural {
            if neural > 1.05 {
                good.append(ShotReason(symbol: "brain", text: "Нейросеть GAIC ставит этот кадр выше соседних вариантов", good: true))
            } else if neural < 0.95 {
                bad.append(ShotReason(symbol: "brain", text: "Нейросеть GAIC оценивает кадр ниже соседних вариантов", good: false))
            }
        }

        return Array((good + bad).prefix(8))
    }
}
