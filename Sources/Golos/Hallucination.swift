import Foundation

/// Ловит выдумки распознавания.
///
/// На неудачном декодировании whisper выдаёт частую фразу из обучающих
/// данных — модель училась на субтитрах, и оттуда лезут концовки роликов:
/// «Всем пока!», «Спасибо за просмотр!», «Субтитры сделал DimaTorzok».
/// Звук при этом нормальный: тот же файл со второй попытки распознаётся верно.
enum Hallucination {
    /// Фразы, которые не диктуют вовсе: подписи из субтитровых файлов
    /// и концовки роликов. Длина и плотность здесь значения не имеют.
    ///
    /// Отдельный список нужен из-за коротких записей. На них плотность
    /// бесполезна: «Продолжение следует» это 19 знаков на 0,74 секунды,
    /// то есть 26 знаков в секунду при пороге в четыре, и проверка
    /// принимает выдумку за живую речь. Порог в полторы секунды до неё
    /// вдобавок не дотягивается. Замер по 241 записи с сохранённым звуком:
    /// короче полутора секунд провалилась почти треть, длиннее ни одна.
    private static let alwaysInvented: [String] = [
        "субтитры сделал",
        "субтитры делал",
        "субтитры создавал",
        "редактор субтитров",
        "корректор а егорова",
        "dimatorzok",
        "subtitles by the amara",
        "продолжение следует",
        "продолжение в следующем видео",
        "до новых встреч",
        "до скорого",
        "ставьте лайки"
    ]

    /// Ядра фраз, которые человек мог сказать и сам. Здесь решает плотность.
    ///
    /// Ищем вхождение, а не совпадение целиком: модель приделывает к ним
    /// приставки. Первая версия проверяла точное равенство и пропустила
    /// «Всем спасибо за просмотр!» — в списке было «спасибо за просмотр».
    ///
    /// «Спасибо за просмотр» и «подписывайтесь» остаются здесь намеренно:
    /// человек, который диктует про ролики и рассылки, говорит их всерьёз.
    private static let suspiciousCores: [String] = [
        "всем пока",
        "всем привет",
        "привет всем",
        "всем здравствуйте",
        "добрый день",
        "добрый вечер",
        "спасибо за просмотр",
        "спасибо за внимание",
        "подписывайтесь на канал",
        "thanks for watching",
        "thank you for watching",
        "please subscribe"
    ]

    /// Короче этого фраза могла быть сказана всерьёз — не трогаем.
    private static let minimumSeconds: TimeInterval = 1.5

    /// Знаков в секунду, ниже которых текст явно не покрывает записанное.
    ///
    /// Обычная речь идёт около десяти знаков в секунду — замерено по полусотне
    /// живых записей. Выдумка даёт полтора: «Всем пока!» на семи секундах речи.
    /// Порог посередине с запасом в обе стороны.
    private static let minimumDensity: Double = 4.0

    static func normalize(_ text: String) -> String {
        let stripped = text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return stripped
    }

    /// Короче этого низкая плотность ни о чём не говорит: за две секунды
    /// человек успевает сказать «Да», и это ответ, а не потеря.
    ///
    /// Было шесть секунд, и мимо прошла запись на 4,3 секунды, где вместо
    /// живой фразы приехало «憂鬱, айфон». Замер по коротким записям истории:
    /// из девяти короче восьми секунд ниже четырёх знаков в секунду упала
    /// ровно одна, та самая сломанная, а ближайшая живая идёт с 7,8.
    private static let thinMinimumSeconds: TimeInterval = 2.5

    /// Текста заметно меньше, чем было речи, что бы в нём ни было написано.
    ///
    /// Отдельно от `looksInvented`, потому что там плотность проверяется
    /// только у знакомых заученных фраз, а модель выдумывает и незнакомые.
    /// Именно так терялся кусок: «Все, что я могу сказать» в списке не значилось,
    /// и до проверки плотности дело не доходило.
    ///
    /// Порог замерен по 195 записям истории: медиана 11,2 знака в секунду,
    /// нижние пять процентов 5,3. Ниже четырёх оказались три записи из 195,
    /// и все три действительно недобраны.
    static func looksThin(text: String, audioDuration: TimeInterval) -> Bool {
        guard audioDuration >= thinMinimumSeconds else { return false }
        return Double(text.count) / audioDuration < minimumDensity
    }

    /// Чужая письменность в тексте: иероглифы, кана, хангыль, арабица.
    ///
    /// Для диктовки на русском это верный признак сорвавшегося декодера,
    /// а не речи. Правило точное: сказать иероглиф голосом нельзя.
    static func containsForeignScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0590...0x05FF,   // иврит
                 0x0600...0x06FF,   // арабица
                 0x0900...0x097F,   // деванагари
                 0x0E00...0x0E7F,   // тайская
                 0x1100...0x11FF,   // хангыль, чамо
                 0x3040...0x30FF,   // хирагана и катакана
                 0x3400...0x4DBF,   // иероглифы, расширение A
                 0x4E00...0x9FFF,   // иероглифы
                 0xAC00...0xD7AF:   // хангыль, слоги
                return true
            default:
                return false
            }
        }
    }

    /// Языки, для которых проверка на чужую письменность бессмысленна.
    static let scriptExempt: Set<String> = ["ja", "zh", "ko", "ar", "he", "th", "hi", "auto"]

    /// Похоже ли, что модель выдумала это вместо реальной речи.
    ///
    /// Одного совпадения с заученной фразой мало: «Спасибо за просмотр этого
    /// макета» человек мог сказать сам. Решает плотность — сколько знаков
    /// приходится на секунду записи.
    static func looksInvented(text: String, audioDuration: TimeInterval) -> Bool {
        let normalized = normalize(text)

        if alwaysInvented.contains(where: { normalized.contains($0) }) { return true }

        guard audioDuration >= minimumSeconds else { return false }
        guard suspiciousCores.contains(where: { normalized.contains($0) }) else { return false }

        return Double(text.count) / audioDuration < minimumDensity
    }

    /// Заученные концовки. Проверяются только как хвост: «Всем привет»
    /// в начале речи законно, а после двадцати секунд диктовки — уже нет.
    private static let trailingPhrases: [String] = [
        "всем пока",
        "всем привет",
        "всем спасибо за просмотр",
        "спасибо за просмотр",
        "спасибо за внимание",
        "продолжение следует",
        "подписывайтесь на канал",
        "ставьте лайки",
        "до новых встреч",
        "субтитры сделал dimatorzok",
        "субтитры сделал",
        "редактор субтитров",
        "thanks for watching",
        "please subscribe"
    ]

    /// Столько слов должно остаться, чтобы отсечение имело смысл.
    private static let minimumRemainderWords = 3
    /// Дальше по словам вглубь хвост не ищем.
    private static let maxTailWords = 6

    /// Срезает заученную фразу, приклеенную в конец правильного текста.
    ///
    /// Второй способ, которым лезут субтитры: основной текст распознан верно,
    /// а в хвост добавляется концовка ролика. Плотность всего текста при этом
    /// нормальная, и проверка по нему такое не видит.
    ///
    /// Ищем по словам, а не по предложениям: разделителя перед выдумкой может
    /// не быть вовсе — «Как-то можно сделать, чтобы Спасибо за просмотр!».
    static func strippingTrailingInvention(_ text: String) -> String {
        var words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        while true {
            var cut = 0
            for tailCount in 1...maxTailWords where words.count - tailCount >= minimumRemainderWords {
                let tail = words.suffix(tailCount).joined(separator: " ")
                if trailingPhrases.contains(normalize(tail)) { cut = tailCount }
            }
            guard cut > 0 else { break }

            let removed = words.suffix(cut).joined(separator: " ")
            Log.write("срезал приклеенное в конец: «\(removed)»")
            words.removeLast(cut)
        }

        return words.joined(separator: " ")
    }

    // MARK: - Зацикливание

    /// Сколько повторов подряд считаем сбоем, а не речью.
    private static let minimumRepeats = 3
    /// Какую долю текста должен занимать повтор, чтобы признать его выдумкой.
    private static let degenerateShare = 0.7
    /// Длина повторяющейся группы, которую ищем.
    private static let repeatGroupSizes = 1...4

    /// Весь ли текст — это одно зациклившееся место.
    ///
    /// Whisper иногда срывается в повтор: шесть секунд речи дают «Ссылка на
    /// сайт» пять раз подряд и больше ничего. Отличаем от живой речи по доле:
    /// когда человек сам повторяет фразу, вокруг остаётся другой текст.
    static func looksDegenerate(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 4 else { return false }

        let (count, size, _) = longestRun(in: words)
        guard count >= minimumRepeats else { return false }
        return Double(count * size) / Double(words.count) >= degenerateShare
    }

    /// Схлопывает повтор, если он прилип к концу правильного текста.
    ///
    /// Только к концу: в середине повтор обычно настоящий — человек
    /// пересказывает, что ему выдало приложение.
    static func collapsingTrailingRepeats(_ text: String) -> String {
        var words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        for size in repeatGroupSizes.reversed() {
            guard words.count >= size * minimumRepeats else { continue }

            var repeats = 1
            var start = words.count - size
            while start - size >= 0,
                  normalizedGroup(words, start - size, size) == normalizedGroup(words, start, size) {
                repeats += 1
                start -= size
            }

            if repeats >= minimumRepeats {
                let removed = (repeats - 1) * size
                Log.write("схлопнул повтор в конце: «\(words.suffix(removed).joined(separator: " "))»")
                words.removeLast(removed)
                return words.joined(separator: " ")
            }
        }
        return text
    }

    /// Самый длинный ряд одинаковых групп: сколько повторов и какой длины.
    private static func longestRun(in words: [String]) -> (count: Int, size: Int, start: Int) {
        var best = (count: 0, size: 0, start: 0)
        for size in repeatGroupSizes {
            var index = 0
            while index + size * 2 <= words.count {
                var repeats = 1
                while index + size * (repeats + 1) <= words.count,
                      normalizedGroup(words, index, size)
                        == normalizedGroup(words, index + size * repeats, size) {
                    repeats += 1
                }
                if repeats * size > best.count * best.size {
                    best = (repeats, size, index)
                }
                index += 1
            }
        }
        return best
    }

    private static func normalizedGroup(_ words: [String], _ start: Int, _ size: Int) -> String {
        normalize(words[start..<(start + size)].joined(separator: " "))
    }

    // MARK: - Начало куска

    /// Приветствия, которыми декодер «разогревается» на старте отрезка.
    ///
    /// Проверяются только у кусков со второго: в начале самой диктовки
    /// приветствие законно, а в середине фразы, разрезанной пополам, — нет.
    private static let leadingPhrases: [String] = [
        "всем привет",
        "привет всем",
        "всем здравствуйте",
        "здравствуйте всем",
        "добрый день",
        "добрый вечер",
        "спасибо за просмотр",
        "продолжение следует",
        "субтитры сделал",
        "редактор субтитров"
    ]

    /// Сколько слов должно остаться после среза начала.
    private static let minimumAfterLeading = 4
    private static let maxLeadingWords = 4

    /// Срезает приветствие, приклеенное в начало куска.
    ///
    /// Применять только к кускам со второго — иначе съест законное
    /// приветствие в начале речи.
    static func strippingLeadingInvention(_ text: String) -> String {
        var words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        while true {
            var cut = 0
            for headCount in 1...maxLeadingWords where words.count - headCount >= minimumAfterLeading {
                let head = words.prefix(headCount).joined(separator: " ")
                if leadingPhrases.contains(normalize(head)) { cut = headCount }
            }
            guard cut > 0 else { break }

            Log.write("срезал приклеенное в начало: «\(words.prefix(cut).joined(separator: " "))»")
            words.removeFirst(cut)
        }

        return words.joined(separator: " ")
    }
}
