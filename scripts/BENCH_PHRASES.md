# Benchmark Phrases — VoiceType WER/RTF Test Dataset

Recordings: `Tests/Fixtures/bench/01.wav` through `25.wav` (16 kHz mono PCM).
Reference text: `Tests/Fixtures/bench/01.txt` through `25.txt` (one phrase per file, exact text below).

The dataset covers six categories that stress voice-typing on Russian + English code-switch:

## Block 1 — Russian conversational (5)
01. Сегодня хочу поработать над проектом и посмотреть как оно работает в реальных условиях.
02. Нам нужно подумать как улучшить производительность приложения.
03. Я не уверен что эта идея сработает но попробовать стоит.
04. Завтра встреча с командой по поводу нового функционала.
05. Проверь пожалуйста этот код и напиши свой отзыв.

## Block 2 — Tech anglicisms (5)
06. Запушь этот commit в main и создай pull request.
07. Деплой пока упал на стейджинге, нужно посмотреть в логах что произошло.
08. Я добавил новый middleware в auth flow для проверки токена.
09. Откатим этот merge и попробуем заново через rebase.
10. В кэше Redis висят старые ключи, нужно сделать flush.

## Block 3 — Code-switch (5)
11. Открой файл server.js и поменяй порт на восемь тысяч.
12. В функции handleRequest есть баг с null проверкой.
13. Пакет react-query обновили, нужно перенести useQuery на новый api.
14. Убери console.log из production кода и проверь линтером.
15. Настрой webhook на endpoint slash api slash events.

## Block 4 — Numbers and versions (3)
16. Версия один точка два точка три, билд номер пятьсот двадцать четыре.
17. Запрос обработался за двести пятьдесят миллисекунд, это в три раза быстрее.
18. Сервер на ip адресе сто девяносто два точка один шестьдесят восемь точка один точка сто.

## Block 5 — Long / fast speech (4)
19. Я тут смотрел документацию и понял что нам надо переписать вот этот сервис потому что он слишком медленно работает с большим количеством запросов одновременно.
20. Если ты успеешь до пятницы то давай мы это в релиз включим иначе перенесём на следующий спринт там посмотрим.
21. Окей я понял что ты имеешь в виду давай тогда так и сделаем.
22. Бэкенд возвращает четыреста четвёртую ошибку только когда юзер не авторизован при этом фронт показывает белый экран без какой-либо информации.

## Block 6 — Edge cases (3)
23. (silence — record 5 seconds of room tone with no speech)
24. Раз два три.
25. Это последняя фраза в нашем тесте, спасибо что записали все двадцать пять.

---

## How recordings are used

- `01.txt` through `25.txt` contain the reference text exactly as transcribed (lowercase, no punctuation deletion needed — WER scoring normalizes).
- `23.txt` is empty (silence test — any output is hallucination, lower is better).
- `scripts/bench.sh` (future) will run each model against each WAV, compute WER per phrase, and aggregate.
