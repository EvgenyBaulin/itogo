import Foundation

/// Every scenario of the guide. A new noticeable feature of a version brings a card to that
/// version's «Что нового» and, when there is something to do, a task of the tutorial.
public enum GuideCatalog {
  public static var scenarios: [GuideScenario] { [firstLaunch, tutorial] + whatsNew }

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
        done: .scheduledPaymentAdded),
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

  public static let whatsNew: [GuideScenario] = [whatsNew14]

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
}
