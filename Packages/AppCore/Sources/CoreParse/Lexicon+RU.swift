import CoreKit
import Foundation

/// Russian half of the entry-line vocabulary. Every spelling is written the way the
/// normaliser produces it: lower case and "ё" already folded into "е".
extension Lexicon {
  static let russianKindPhrases: [Phrase<TransactionKind>] = [
    Phrase("возврат денег", .reimbursement),
    Phrase("возврат средств", .reimbursement),
    Phrase("вернули долг", .reimbursement),
    Phrase("возврат", .refund),
    Phrase("возврата", .refund),
    Phrase("вернул покупку", .refund),
    Phrase("доход", .income),
    Phrase("доходы", .income),
    Phrase("зарплата", .income),
    Phrase("зп", .income),
    Phrase("аванс", .income),
  ]

  /// «Аванс» is the advance on a salary — income — until «за» names a job it pays for:
  /// «аванс за ремонт» is a prepayment, an expense. A month behind «за» is still the salary:
  /// «аванс за сентябрь», «аванс за этот месяц».
  static let russianAdvanceWords: Set<String> = ["аванс"]
  static let russianAdvanceMarker = "за"
  static let russianSalaryPeriods: Set<String> = [
    "январь", "февраль", "март", "апрель", "май", "июнь", "июль", "август", "сентябрь",
    "октябрь", "ноябрь", "декабрь", "месяц", "полмесяца",
  ]

  /// Offsets in days from "today".
  static let russianDatePhrases: [Phrase<Int>] = [
    Phrase("сегодня", 0),
    Phrase("вчера", -1),
    Phrase("позавчера", -2),
  ]

  /// Read anywhere in the line, so only in the dative the spec lists («девушке», «друзьям»,
  /// «семье»): whom the money went to. The nominative is the one doing something — «муж
  /// заправил машину» — and stays in the note.
  static let russianForWhomWords: [String: ForWhom] = [
    "себе": .me,
    "мне": .me,
    "девушке": .partner,
    "партнеру": .partner,
    "жене": .partner,
    "мужу": .partner,
    "парню": .partner,
    "другу": .friends,
    "друзьям": .friends,
    "семье": .family,
    "родителям": .family,
    "маме": .family,
    "папе": .family,
    "детям": .family,
  ]

  /// The same words in the case «для» asks for. Read only right after the marker, never in
  /// a blind scan of the line: «от мамы» is not «для мамы», «позвал друзей» is not «для
  /// друзей». Written out instead of matched by a stem, because a stem also matches names:
  /// «Жени» and «жены» share «жен».
  static let russianDeclinedForWhomWords: [String: ForWhom] = [
    "себя": .me,
    "друзей": .friends,
    "девушки": .partner,
    "партнера": .partner,
    "партнерши": .partner,
    "жены": .partner,
    "мужа": .partner,
    "парня": .partner,
    "друга": .friends,
    "семьи": .family,
    "родителей": .family,
    "мамы": .family,
    "папы": .family,
    "детей": .family,
  ]

  static let russianCurrencyWords: [String: String] = [
    "р": "RUB", "руб": "RUB", "рубль": "RUB", "рубля": "RUB", "рублей": "RUB",
    "рублях": "RUB", "рубли": "RUB",
    "доллар": "USD", "доллара": "USD", "долларов": "USD", "долларах": "USD",
    "бакс": "USD", "баксов": "USD",
    "евро": "EUR",
    "тенге": "KZT",
    "юань": "CNY", "юаня": "CNY", "юаней": "CNY",
    "лира": "TRY", "лиры": "TRY", "лир": "TRY",
    "дирхам": "AED", "дирхама": "AED", "дирхамов": "AED",
    "лари": "GEL",
    "драм": "AMD", "драма": "AMD", "драмов": "AMD",
    "бат": "THB", "бата": "THB", "батов": "THB",
  ]

  /// Possessives that stand between a marker and the word it introduces: «для моей мамы»,
  /// «в нашей столовой». Every case of «мой», «твой», «свой», «наш», «ваш», and «его», «её»,
  /// «их», which do not decline.
  static let russianDeterminers: Set<String> = [
    "мой", "моя", "мое", "мои", "моего", "моей", "моему", "моим", "моих", "мою", "моими",
    "твой", "твоя", "твое", "твои", "твоего", "твоей", "твоему", "твоим", "твоих", "твою",
    "твоими",
    "свой", "своя", "свое", "свои", "своего", "своей", "своему", "своим", "своих", "свою",
    "своими",
    "наш", "наша", "наше", "наши", "нашего", "нашей", "нашему", "нашим", "наших", "нашу",
    "нашими",
    "ваш", "ваша", "ваше", "ваши", "вашего", "вашей", "вашему", "вашим", "ваших", "вашу",
    "вашими",
    "его", "ее", "их",
    "этот", "эта", "это", "эти", "этого", "этой", "этому", "этим", "этих", "эту", "этими",
  ]

  /// When, not where: a weekday, a month or a time of day behind «в» / «во» is not a place
  /// («в среду», «в январе», «в обед»). It stays in the note; the spec's dates are only the
  /// keywords and «12.09».
  static let russianTimeWords: Set<String> = [
    "понедельник", "вторник", "среда", "среду", "четверг", "пятница", "пятницу", "суббота",
    "субботу", "воскресенье", "выходные", "выходной",
    "январе", "феврале", "марте", "апреле", "мае", "июне", "июле", "августе", "сентябре",
    "октябре", "ноябре", "декабре",
    "обед", "полдень", "полночь", "ночь",
  ]

  /// Words that make the number in front of them a count or a day, not money: «2 шт»,
  /// «1,5 кг», «3 ночи», «8 марта».
  static let russianWordsAfterACount: Set<String> = [
    "шт", "штук", "штуки", "штука", "уп", "упак", "упаковки", "упаковок", "пачки", "пачек",
    "бутылки", "бутылок", "кг", "г", "гр", "грамм", "граммов", "л", "литр", "литра", "литров",
    "мл",
    "час", "часа", "часов", "мин", "минут", "минуты", "дня", "дней", "ночи", "ночей", "недели",
    "недель", "месяца", "месяцев",
    "января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября",
    "октября", "ноября", "декабря",
  ]

  static let russianPersonMarkers: Set<String> = ["для"]
  static let russianPlaceMarkers: Set<String> = ["в", "во"]
  static let russianGoalMarkers: Set<String> = ["цель", "цели", "целей", "накопление"]
  static let russianDebtMarkers: Set<String> = [
    "кредит", "кредиту", "кредита", "долг", "долгу", "долга", "займ", "займу", "ипотека",
  ]
}
