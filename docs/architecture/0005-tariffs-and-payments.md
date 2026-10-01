# Тарифы и mock-оплата (этап 4)

## Тарифы

Клиент показывает четыре линейных тарифа по 250 ₽ за месяц: 1/250, 3/750,
6/1500 и 12/3000. Скидки, зачёркнутые цены и неподтверждённые маркетинговые
утверждения отсутствуют.

## Платёжный автомат

`PaymentProvider` публикует текущее состояние и поток переходов:

```text
idle -> creatingOrder -> awaitingPayment
                            |       |
                            |       +-> cancelled
                            +-> paid -> subscriptionUpdating -> paid
                            `-> failed
```

Development использует явно помеченный `MockPaymentProvider`. Подтверждение в
нём возможно только отдельной кнопкой «Симулировать подтверждение».

Release получает `UnavailablePaymentProvider`: кнопки создания заказа и mock
подтверждения отсутствуют, а UI прямо сообщает, что backend не подключён. Этот
адаптер всегда возвращает `false` при попытке подтверждения и не может перейти
в `paid`.

## Production-граница

Production-провайдер не реализован. Требуемые API и webhook-инварианты описаны в
[`../server-payments-required-stage4.md`](../server-payments-required-stage4.md).
Клиент никогда не должен считать checkout redirect или локальный callback
доказательством оплаты.
