import Foundation

/// Every scenario of the guide. A new noticeable feature of a version brings a card to that
/// version's «Что нового» and, when there is something to do, a task of the tutorial.
public enum GuideCatalog {
  public static var scenarios: [GuideScenario] { [firstLaunch, tutorial] + whatsNew }

  /// The tasks of the tutorial for an owner who told the starter set `profile` (nil — no set):
  /// the tasks for everyone, the ones of his ways of living and answers, and none about a life
  /// the set says is not his.
  public static func tutorialTasks(for profile: GuideProfile?) -> [GuideTask] {
    tutorial.tasks.filter { $0.audience.includes(profile) }
  }

  // MARK: First launch

  public static let firstLaunch = GuideScenario(
    kind: .firstLaunch,
    cards: [
      GuideCard(
        id: "first.welcome",
        title: GuideText("Итого — учёт денег на этом Mac", "Itogo keeps your money on this Mac"),
        body: GuideText(
          "Записывайте траты и доходы, а Итого посчитает, куда уходят деньги и сколько можно тратить.",
          "Write down what you spend and earn; Itogo works out where the money goes and how much you can spend."
        ),
        symbol: "sum"),
      GuideCard(
        id: "first.line",
        title: GuideText("Одна строка — одна запись", "One line, one record"),
        body: GuideText(
          "Наберите «кофе 300» и нажмите Return. Сумма, дата и счёт понимаются из строки; Tab открывает все поля.",
          "Type «coffee 300» and press Return. Amount, date and account are read from the line; Tab opens every field."
        ),
        symbol: "text.cursor"),
      GuideCard(
        id: "first.categories",
        title: GuideText("Категории и оценка", "Categories and a verdict"),
        body: GuideText(
          "Каждая трата — в категории и с оценкой: хорошая, обычная или плохая. Итого учится на вашем выборе.",
          "Every expense has a category and a verdict: good, ordinary or bad. Itogo learns from your choices."
        ),
        symbol: "square.grid.2x2"),
      GuideCard(
        id: "first.accounts",
        title: GuideText("Счета и сверка", "Accounts and counts"),
        body: GuideText(
          "Банк, счёт, карта. Раз в неделю сверьте остаток — разница станет видна сразу.",
          "Bank, account, card. Count the balance once a week and any difference shows at once."
        ),
        symbol: "building.columns"),
      GuideCard(
        id: "first.planning",
        title: GuideText("Сколько можно тратить", "What is free to spend"),
        body: GuideText(
          "Платежи, подписки, цели и лимиты — в «Планировании». Свободная сумма учитывает их все.",
          "Payments, subscriptions, goals and limits live in Planning. The free amount takes them all into account."
        ),
        symbol: "calendar"),
      GuideCard(
        id: "first.privacy",
        title: GuideText("Ваши данные — только у вас", "Your data stays with you"),
        body: GuideText(
          "База лежит на этом Mac. В сеть уходят только запросы курсов ЦБ и проверка обновлений.",
          "The database stays on this Mac. Only exchange rates and update checks go to the network."
        ),
        symbol: "lock.shield"),
      GuideCard(
        id: "first.help",
        title: GuideText("Учитесь на учебных данных", "Practise on sample data"),
        body: GuideText(
          "«Справка → Учебный режим» — задания на учебной базе, ваша не трогается. «Справка → Показать, куда нажимать» — подписи на экране.",
          "Help → Tutorial gives you tasks on sample data; yours is not touched. Help → Show Where to Click labels the screen."
        ),
        symbol: "graduationcap"),
    ])

  // MARK: Tutorial

  public static let tutorial = GuideScenario(
    kind: .tutorial,
    tasks: [
      GuideTask(
        id: "task.coffee",
        title: GuideText("Запишите «кофе 300»", "Write down «coffee 300»"),
        hints: [
          GuideHint(
            target: "entry.line",
            text: GuideText(
              "Наберите в строке внизу «кофе 300» и нажмите Return",
              "Type «coffee 300» in the line below and press Return"),
            keys: "⌘N", gesture: GuideText("Коснитесь строки ввода", "Tap the entry line"))
        ],
        done: .any([
          .operation(words: "кофе", amountE4: 3_000_000),
          .operation(words: "coffee", amountE4: 3_000_000),
        ])),
      // The tasks of a starter set: each writes into a category the set adds, so the owner sees
      // where his own spending goes.
      GuideTask(
        id: "task.textbook",
        title: GuideText("Запишите покупку учебника", "Write down a textbook"),
        hints: [
          GuideHint(
            target: "entry.line",
            text: GuideText(
              "Наберите «учебник 800» — для таких трат набор добавил «Учебники»",
              "Type «textbook 800»: the set added «Textbooks» for it"))
        ],
        done: .any([
          .operation(words: "учебник", amountE4: nil), .operation(words: "textbook", amountE4: nil),
        ]),
        audience: .only(.lifestyle(.student))),
      GuideTask(
        id: "task.lunch",
        title: GuideText("Запишите обед", "Write down a lunch"),
        hints: [
          GuideHint(
            target: "entry.line",
            text: GuideText(
              "Наберите «обед 450» — для этого набор добавил «Обеды»",
              "Type «lunch 450»: the set added «Lunches» for it"))
        ],
        done: .any([
          .operation(words: "обед", amountE4: nil), .operation(words: "lunch", amountE4: nil),
        ]),
        audience: .only(.lifestyle(.working))),
      GuideTask(
        id: "task.client",
        title: GuideText("Запишите оплату от заказчика", "Write down a payment from a client"),
        hints: [
          GuideHint(
            target: "entry.line",
            text: GuideText(
              "Наберите «+20000 заказчик» — доход ляжет в «Заказчики» из набора",
              "Type «+20000 client»: the income goes to «Clients» of the set"))
        ],
        done: .any([.income(words: "заказ"), .income(words: "client")]),
        audience: .only(.lifestyle(.freelance))),
      GuideTask(
        id: "task.familyHelp",
        title: GuideText("Запишите помощь родным", "Write down help to your family"),
        hints: [
          GuideHint(
            target: "entry.line",
            text: GuideText(
              "Наберите «помощь маме 3000» — для этого набор добавил «Помощь родным»",
              "Type «help mum 3000»: the set added «Family help» for it"))
        ],
        done: .any([
          .operation(words: "помощ", amountE4: nil), .operation(words: "help", amountE4: nil),
        ]),
        audience: .only(.lifestyle(.family))),
      GuideTask(
        id: "task.date",
        title: GuideText("Запишите свидание", "Write down a date"),
        hints: [
          GuideHint(
            target: "entry.line",
            text: GuideText(
              "Наберите «свидание 2500» — для этого набор добавил «Свидания»",
              "Type «date 2500»: the set added «Dates» for it"))
        ],
        done: .any([
          .operation(words: "свидан", amountE4: nil), .operation(words: "date", amountE4: nil),
        ]),
        audience: .only(.lifestyle(.partner))),
      GuideTask(
        id: "task.kids",
        title: GuideText("Запишите покупку для детей", "Write down something for the children"),
        hints: [
          GuideHint(
            target: "entry.line",
            text: GuideText(
              "Наберите «игрушки 1500» — набор добавил категорию «Дети»",
              "Type «toys 1500»: the set added the category «Kids»"))
        ],
        done: .any([
          .operation(words: "игрушк", amountE4: nil), .operation(words: "toy", amountE4: nil),
        ]),
        audience: .only(.lifestyle(.kids))),
      GuideTask(
        id: "task.category",
        title: GuideText("Поменяйте категорию операции", "Change the category of an operation"),
        hints: [
          GuideHint(
            target: "sidebar.spending",
            text: GuideText(
              "Откройте «Траты», дважды щёлкните операцию и выберите другую категорию",
              "Open Spending, double-click an operation and pick another category"),
            gesture: GuideText("Коснитесь операции", "Tap an operation"))
        ],
        done: .event(GuideEvent.categoryChanged)),
      GuideTask(
        id: "task.search",
        title: GuideText("Найдите трату за прошлую неделю", "Find an expense from last week"),
        hints: [
          GuideHint(
            target: "transactions.search",
            text: GuideText(
              "В «Тратах» наберите слово в поиске", "Type a word into the search of Spending"),
            keys: "⌘F")
        ],
        done: .event(GuideEvent.searched)),
      GuideTask(
        id: "task.subscription",
        title: GuideText("Заведите платёж по подписке", "Add a subscription payment"),
        hints: [
          GuideHint(
            target: "planning.addPayment",
            text: GuideText("«Планирование» → «+ Платёж»", "Planning → «+ Payment»"), keys: "⌘2")
        ],
        done: .scheduledPaymentAdded,
        audience: .unlessNot(.subscriptions)),
      GuideTask(
        id: "task.count",
        title: GuideText("Сверьте остаток счёта", "Count the balance of an account"),
        hints: [
          GuideHint(
            target: "toolbar.reconcile",
            text: GuideText(
              "Кнопка «Сверка» на панели инструментов", "The Count button of the toolbar"))
        ],
        done: .countMade),
      GuideTask(
        id: "task.free",
        title: GuideText(
          "Посмотрите, сколько свободно до конца месяца", "See what is free to spend this month"),
        hints: [
          GuideHint(
            target: "planning.freeToSpend",
            text: GuideText(
              "«Планирование», блок «Свободная сумма»", "Planning, the Free to Spend block"),
            keys: "⌘2")
        ],
        done: .event(GuideEvent.freeToSpendSeen)),
      GuideTask(
        id: "task.transfer",
        title: GuideText("Переведите деньги строкой", "Transfer money from the line"),
        hints: [
          GuideHint(
            target: "entry.line",
            text: GuideText(
              "Наберите «перевод 1000 основной наличные»", "Type «transfer 1000 main cash»"))
        ],
        done: .any([.event(GuideEvent.transferFromLine), .transferAdded])),
      GuideTask(
        id: "task.forSomebody",
        title: GuideText("Заплатите за другого", "Pay for somebody else"),
        hints: [
          GuideHint(
            target: "entry.forWhom",
            text: GuideText(
              "В панели ↓ строка «За кого» → «За другого» или «Пополам»",
              "In the ↓ panel, «For whom» → «For somebody» or «Half each»"),
            keys: "Tab")
        ],
        done: .operationForSomebodyElse),
      GuideTask(
        id: "task.loan",
        title: GuideText("Заведите кредит или долг", "Add a loan or a debt"),
        hints: [
          GuideHint(
            target: "sidebar.debts",
            text: GuideText("«Долги» → «+ Долг»", "Debts → «+ Debt»"), keys: "⌘3")
        ],
        done: .debtAdded,
        audience: .only(.loans)),
      GuideTask(
        id: "task.cushion",
        title: GuideText("Заведите цель «Подушка»", "Add a goal «Cushion»"),
        hints: [
          GuideHint(
            target: "sidebar.planning",
            text: GuideText("«Планирование» → «+ Цель»", "Planning → «+ Goal»"), keys: "⌘2")
        ],
        done: .goalAdded,
        audience: .only(.cushion)),
      GuideTask(
        id: "task.cashback",
        title: GuideText("Задайте кэшбэк счёта", "Set the cashback of an account"),
        hints: [
          GuideHint(
            target: "settings.accounts",
            text: GuideText(
              "«Настройки → Счета» → счёт → «Кэшбэк…»",
              "Settings → Accounts → an account → «Cashback…»"),
            keys: "⌘,")
        ],
        done: .cashbackRuleAdded,
        audience: .only(.cashback)),
      GuideTask(
        id: "task.spending",
        title: GuideText("Откройте список «Траты»", "Open the Spending list"),
        hints: [
          GuideHint(
            target: "sidebar.spending",
            text: GuideText(
              "Пункт «Траты» в боковой панели или ↓ в пустой строке",
              "Spending in the sidebar, or ↓ in the empty line"),
            keys: "↓")
        ],
        done: .event(GuideEvent.spendingOpened)),
      GuideTask(
        id: "task.currencyChart",
        title: GuideText("Посмотрите график валюты", "Look at a currency chart"),
        hints: [
          GuideHint(
            target: "settings.overviewTiles",
            text: GuideText(
              "«Настройки → Оформление» → плитка «График валюты»",
              "Settings → Appearance → the Currency Chart tile"),
            keys: "⌘,")
        ],
        done: .event(GuideEvent.currencyChartSeen)),
    ])

  // MARK: What is new

  public static let whatsNew: [GuideScenario] = [
    whatsNew14, whatsNew15, whatsNew16, whatsNew17,
  ]

  public static let whatsNew14 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 1, minor: 4)),
    cards: [
      GuideCard(
        id: "new14.guide",
        title: GuideText("Знакомство и учебный режим", "A tour and a tutorial"),
        body: GuideText(
          "«Справка → Учебный режим»: задания на учебных данных, ваша база не трогается.",
          "Help → Tutorial: tasks on sample data, your database is not touched."),
        symbol: "graduationcap"),
      GuideCard(
        id: "new14.starter",
        title: GuideText("Стартовые наборы", "Starter sets"),
        body: GuideText(
          "«Настройки → Стартовый набор»: категории и лимиты под ваш образ жизни. Набор только добавляет.",
          "Settings → Starter Set: categories and limits for the way you live. A set only adds."),
        symbol: "shippingbox"),
      GuideCard(
        id: "new14.spending",
        title: GuideText("«Траты» в боковой панели", "Spending in the sidebar"),
        body: GuideText(
          "Все операции — отдельным списком. ↓ в пустой строке переходит к самой новой.",
          "Every operation in a list of its own. ↓ in the empty line goes to the latest."),
        symbol: "list.bullet"),
      GuideCard(
        id: "new14.approx",
        title: GuideText("Серое «≈» для чужой валюты", "A grey «≈» for other currencies"),
        body: GuideText(
          "Трата в долларах без курса показывает «≈ 1,240 ₽» по курсу ЦБ. Только показ — цифры не меняются.",
          "A dollar expense without a rate shows «≈ 1,240 ₽» at the central bank's rate. Display only."
        ),
        symbol: "approximately.equal"),
      GuideCard(
        id: "new14.currencyChart",
        title: GuideText("График валюты на Обзоре", "A currency chart on the Overview"),
        body: GuideText(
          "Плитка с парой валют, неделя, месяц или год, курс и изменение.",
          "A tile with a currency pair over a week, month or year, the rate and the change."),
        symbol: "chart.xyaxis.line"),
      GuideCard(
        id: "new14.forSomebody",
        title: GuideText("Трата за другого", "Paying for somebody"),
        body: GuideText(
          "«За кого»: себе, за другого, пополам, поровну. «Вернёт?» — долг или подарок.",
          "«For whom»: me, somebody else, half each, split evenly. «Pays back?» — a debt or a gift."
        ),
        symbol: "person.2"),
      GuideCard(
        id: "new14.transfer",
        title: GuideText("Перевод строкой", "A transfer from the line"),
        body: GuideText(
          "«перевод 5000 сбер т-банк» — перевод со счёта на счёт, а не трата.",
          "«transfer 5000 sber tbank» moves money between accounts; it is not spending."),
        symbol: "arrow.left.arrow.right"),
      GuideCard(
        id: "new14.expected",
        title: GuideText("Ожидаемые поступления", "Expected income"),
        body: GuideText(
          "Можно удалить, закрыть полностью и вернуть из архива; имена могут совпадать.",
          "Delete one, close it in full and bring it back from the archive; names may repeat."),
        symbol: "tray.and.arrow.down"),
      GuideCard(
        id: "new14.quickEntry",
        title: GuideText("Быстрый набор справа", "Quick entry at the side"),
        body: GuideText(
          "В подробной форме справа — строка, которая сначала показывает, что будет записано.",
          "The form at the side has a line that shows what will be written before it is."),
        symbol: "sidebar.right"),
    ])

  public static let whatsNew15 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 1, minor: 5)),
    cards: [
      GuideCard(
        id: "new15.calendar",
        title: GuideText("Календарь трат", "A spending calendar"),
        body: GuideText(
          "Месяц или неделя: сколько потрачено в каждый день, дорогие дни отмечены, впереди — платежи. ⌘5.",
          "A month or a week: what each day cost, costly days marked, payments ahead. ⌘5."),
        symbol: "calendar"),
      GuideCard(
        id: "new15.hide",
        title: GuideText("Скрыть суммы", "Hide amounts"),
        body: GuideText(
          "Кнопка с глазом или ⌃⌘H — все суммы становятся «•••».",
          "The eye button or ⌃⌘H turns every amount into «•••»."),
        symbol: "eye.slash"),
      GuideCard(
        id: "new15.lock",
        title: GuideText("Блокировка Touch ID", "A Touch ID lock"),
        body: GuideText(
          "«Настройки → Основные»: «Итого» закрывается после простоя и при блокировке Mac.",
          "Settings → General: Itogo locks after idle time and when the Mac locks."),
        symbol: "touchid"),
      GuideCard(
        id: "new15.limits",
        title: GuideText("Предложить лимиты", "Suggested limits"),
        body: GuideText(
          "«Планирование → Лимиты → Предложить лимиты…»: суммы по вашим обычным тратам.",
          "Planning → Limits → Suggest Limits…: amounts from what you usually spend."),
        symbol: "gauge.with.dots.needle.50percent"),
      GuideCard(
        id: "new15.line",
        title: GuideText("Время и кэшбэк в строке", "Time and cashback in the line"),
        body: GuideText(
          "«груша вчера в 18:09 325 кэшбек 9.76» — со временем и кэшбэком.",
          "«pear yesterday at 18:09 325 cashback 9.76» — with the time and the cashback."),
        symbol: "text.cursor"),
      GuideCard(
        id: "new15.form",
        title: GuideText("Форма справа", "The form at the side"),
        body: GuideText(
          "Сначала вид операции; выбранная в списке операция открывается в форме на правку; перевод — прямо в форме.",
          "The kind comes first; an operation chosen in a list opens in the form; a transfer is written right there."
        ),
        symbol: "sidebar.right"),
    ])

  public static let whatsNew16 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 1, minor: 6)),
    cards: [
      GuideCard(
        id: "new16.educationLoan",
        title: GuideText("Образовательный кредит", "An education loan"),
        body: GuideText(
          "Новый долг → «Образовательный кредит (госпрограмма)»: 3 %, льготный период с 40 % → 60 % → 100 % процентов, затем 15 лет основного долга.",
          "New debt → «Education loan (state programme)»: 3 %, a grace period paying 40 % → 60 % → 100 % of the interest, then 15 years of main debt."
        ),
        symbol: "graduationcap"),
      GuideCard(
        id: "new16.tranche",
        title: GuideText("Транши и проценты в платежах", "Tranches and the interest in payments"),
        body: GuideText(
          "«Добавить транш…» — расход в «Образовании», долг растёт. Платёж сначала гасит проценты: расходом считаются только они.",
          "«Add Tranche…» is an expense in «Education» and grows the debt. A payment pays the interest first, and only the interest is spending."
        ),
        symbol: "banknote"),
      GuideCard(
        id: "new16.deposits",
        title: GuideText("Вклады и накопительные счета", "Deposits and savings accounts"),
        body: GuideText(
          "В редакторе счёта — «На остаток начисляются проценты»: ставка, выплата, капитализация. Экран счёта покажет начисленное и спросит, если выплата не пришла.",
          "In the account editor, «The balance earns interest»: the rate, the payout, capitalisation. The account screen shows what was earned and asks when a payout does not come."
        ),
        symbol: "percent"),
      GuideCard(
        id: "new16.forecast",
        title: GuideText("Проценты в прогнозе счёта", "Interest in the account forecast"),
        body: GuideText(
          "Прогноз на конец месяца добавляет серую строку «Проценты ≈». «Записать…» — и они становятся доходом.",
          "The forecast for the end of the month adds a grey «Interest ≈» line. «Record…» makes them income."
        ),
        symbol: "chart.line.uptrend.xyaxis"),
    ])

  public static let whatsNew17 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 1, minor: 7)),
    cards: [
      GuideCard(
        id: "new17.capital",
        title: GuideText("Капитал", "Capital"),
        body: GuideText(
          "Что есть минус что должен: счета, вклады, имущество и долги — и график по концам месяцев. ⌘6.",
          "What you have minus what you owe: accounts, deposits, property and debts, with a chart of month ends. ⌘6."
        ),
        symbol: "building.columns"),
      GuideCard(
        id: "new17.assets",
        title: GuideText("Имущество", "Property"),
        body: GuideText(
          "Машина, брокерский счёт, квартира: «Добавить имущество…», потом «Новая оценка…» — стоимость на дату входит в капитал.",
          "A car, a brokerage account, a flat: «Add property…», then «New valuation…» — the value on a day goes into the capital."
        ),
        symbol: "car"),
      GuideCard(
        id: "new17.cushion",
        title: GuideText("Подушка безопасности", "A safety cushion"),
        body: GuideText(
          "«Счета и категории…» — отметьте счета подушки и необходимые траты, и «Капитал» скажет: «Без дохода вы проживёте 3,5 месяца».",
          "«Accounts and categories…»: mark the cushion accounts and the essential spending, and Capital says: «Without income you would last 3.5 months»."
        ),
        symbol: "lifepreserver"),
      GuideCard(
        id: "new17.cushionGoal",
        title: GuideText("Цель подушки", "A cushion goal"),
        body: GuideText(
          "«Цель…» — подушка на N месяцев и сколько откладывать в месяц. «Не считать подушку в свободной сумме» — в «Свободной сумме» и «Настройки → Планирование».",
          "«Goal…» sets a cushion of N months and what to put aside each month. «Keep the cushion out of the free sum» is in «Free sum» and Settings → Planning."
        ),
        symbol: "target"),
    ])
}
