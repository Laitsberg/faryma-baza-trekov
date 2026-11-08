# Роутинг и бэкенд композитора

Как база треков встаёт рядом с бэкендом
[`farymacomposer/webapp`](https://github.com/farymacomposer/webapp/tree/dev)
(ветка `dev`, сверено по коммиту `2aeb7c1` от 14.06.26) и какие
эндпоинты ей от него нужны.

**Коротко.** Сейчас бэкенд умеет вход через Twitch, стримы, заказы
разносов и очередь в реальном времени. **Каталога треков в нём пока
нет**: таблицы `Track*` и `UserTrackRating` в схеме есть, но ни один
эндпоинт и ни один сервис в них не пишет. Из того, чем живёт база,
сейчас можно взять только вход, эфиры и очередь — для студии.
Остальное (каталог, оценки зрителей, профили, привязка ников) придётся
добавить — список ниже, в части 3.

---

## 1. Что есть в бэкенде

* **.NET 10, ASP.NET Core, EF Core + PostgreSQL.** Маршруты —
  `api/[controller]/[action]`: `GET /api/ComposerStream/FindStreams`,
  `POST /api/ReviewOrder/CompleteReviewOrder`. Все изменения — `POST` с
  JSON-телом, чтения — `GET` с параметрами в строке.
* **Перечисления приходят строками** (`"Live"`, `"Donation"`), не
  числами — `JsonStringEnumConverter` и в REST, и в SignalR.
* **Ошибки.** 401 с `{ "Message": "Ошибка аутентификации" }`; доменные
  ошибки — `ResultObject` со своим кодом; ошибки проверки — стандартный
  `ProblemDetails` (400). 429 — лимит.
* **Роли** — `Composer` и `Moderator`; «админы» (`AuthorizeAdmins`) —
  это любая из двух. Роль лежит в JWT (`ClaimTypes.Role`), там же
  `NameIdentifier` (Guid пользователя) и `Name` (логин Twitch).
* **Токены.** Access — JWT на `JWT__EXPIRY_IN_MINUTES` (в `.env` — 60
  минут). Refresh — случайная строка, **при каждом обновлении
  выдаётся новая, а старая отзывается; повторное предъявление
  отозванной гасит всё семейство** (защита от кражи). Отсюда грабли для
  нас — см. 2.4.
* **Лимит `auth-login`** — 10 запросов в минуту с одного IP на *все*
  ручки `Auth`, включая `RefreshToken`.
* **Документация** (Scalar для REST, AsyncAPI для SignalR) включается
  только при `ASPNETCORE_ENVIRONMENT=Development`.
* **CORS не настроен вовсе.** Страница с другого адреса до API не
  достучится — см. 2.1.
* **Фронтенд стрима** (React + react-router) — это чужой «стрим»,
  о котором говорит CLAUDE.md. Маршрут у него сейчас один, `/`, nginx
  отдаёт `index.html` на любой путь. Прод:
  `https://farymacomposer-webapp-44b9.twc1.net`.

---

## 2. Роутинг

### 2.1. Один домен, общий `/api`

Базу и стрим лучше отдавать **с одного адреса**, а `/api/` на нём
проксировать в `webapi:8080` (в `.env` бэкенда для этого уже лежит
`API_PROXY_TARGET`). Причины не вкусовые:

1. **CORS в бэкенде нет.** С отдельного домена (или с GitHub Pages)
   каждый запрос упадёт, пока туда не добавят `UseCors` со списком
   адресов.
2. **Вход через Twitch держится на cookie.** `TwitchLoginState` ставит
   `HttpOnly; Secure; SameSite=Lax` cookie с `Path=/api/Auth/TwitchLogin`,
   и `TwitchLogin` без неё отказывает. С другого сайта браузер эту
   cookie не пришлёт: `fetch` к чужому домену потребовал бы и CORS с
   `AllowCredentials`, и `SameSite=None`.
3. **Адрес возврата у Twitch один** — `TWITCH__REDIRECT_URI`, и он
   должен совпасть с тем, что передали в `authorize`, до символа.

Раскладка путей:

| путь | чьё | что |
|---|---|---|
| `/` и всё, что не ниже | база треков | `baza-trekov.html` на любой путь (`try_files $uri /baza-trekov.html`) |
| `/stream`, `/stream/*` | фронтенд стрима | его `index.html`; ему нужен `basename="/stream"` в роутере и `base: '/stream/'` в Vite |
| `/auth/twitch/callback` | общий | возврат из Twitch, см. 2.4 |
| `/api/*` | бэкенд | прокси на `webapi:8080` |
| `/api/OrderQueueNotificationHub` | бэкенд | SignalR: прокси с `Upgrade`/`Connection` для WebSocket |
| `/covers.json`, `/facts.json` | база | как сейчас, рядом со страницей |

Кому достаётся корень — решение заказчика. Предлагаю базе: она и
есть главная («Здесь мы оцениваем музыку»), а пункт шапки «стрим» уже
ведёт наружу. Если корень отдадут стриму, база переезжает в `/base`,
а в таблице меняется только префикс.

Пример nginx (в `frontend/nginx.conf` бэкенда сейчас только SPA-раздача):

```nginx
location /api/OrderQueueNotificationHub {
    proxy_pass http://webapi:8080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 1h;
}
location /api/ {
    proxy_pass http://webapi:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
location /stream/ { try_files $uri /stream/index.html; }
location /       { try_files $uri /baza-trekov.html; }
```

`X-Forwarded-For` важен: лимит `auth-login` считает по IP, и без
`UseForwardedHeaders` в бэкенде все зрители окажутся одним адресом
прокси — десять входов в минуту на всех.

### 2.2. Решётка остаётся, пути — сверху

Сейчас маршруты страницы — в решётке (`route()` на `hashchange`), и
это держит главное свойство файла: он открывается двойным кликом и
работает без сети. Ломать это не надо. Предложение:

* **Решётка — по-прежнему источник правды внутри страницы.** Вся
  логика `route()`, `навигация()`, `history.scrollRestoration` не
  меняется.
* **На сервере понимаем и пути.** При загрузке, если
  `location.protocol` не `file:` и путь не корень, путь переводится в
  решётку (`history.replaceState`) по таблице ниже — и дальше работает
  то, что уже есть. Так ссылки вида `/t/1234` можно давать наружу (их
  понимают превью в Telegram и Discord, если однажды захочется отдавать
  `og:`-теги сервером), а старые `#t=…` продолжают работать.
* **Переходить на пути внутри страницы (pushState вместо решётки) —
  отдельным шагом и только если понадобится.** Выигрыш — красивые
  адреса; цена — переписать все `href="#…"` и `hashchange`, а для
  `file://` всё равно держать решётку.

### 2.3. Таблица маршрутов

| экран | сейчас | на сервере (предложение) | примечание |
|---|---|---|---|
| главная | `` (корень) | `/` | |
| каталог | `#base` | `/base` | фильтры в адрес пока не кладём |
| трек | `#t=<ключ>` | `/t/<trackId>` | ключ сейчас — `номер_эфира\|название`; когда треки появятся в бэкенде, адресом станет `Track.Id`, а старый ключ — переадресацией (как уже делается с ключом без номера) |
| трек, к комментарию | `#t=<ключ>&c=<id>` | `/t/<trackId>?c=<id>` | |
| трек, конкретный разнос повтора | — (`T.раз` внутри) | `/t/<trackId>?raz=<reviewId>` | `reviewId` — `Review.Id` бэкенда |
| рецензия зрителя | `#r=<id>` | `/r/<id>` | **не путать с `Review` бэкенда**: там `Review` — это разнос композитора (оценка + тайм-код записи), а у нас «рецензия» — текст зрителя |
| чужой профиль | `#u=<логин>` | `/u/<логин>` | логин Twitch, строчными |
| кабинет | `#me`, `#me/<вкладка>` | `/me`, `/me/<вкладка>` | вкладки: `ratings`, `favs`, `orders`, `wishes`, `playlist`, `settings`, `claims`, `manage` |
| режим оценки | `#rate` | `/rate` | |
| прикольчики | `#fun` | `/fun` | |
| студия оценок | `#studio` | `/studio` | вид, а не защита: доступ решает роль в бэкенде (часть 3) |
| обложки и факты | `#covers` | `/covers` | |
| эфир (новое) | — | `/s/<streamId>` | что разнесли в эфире, итог; данные — `ComposerStream` + `Review` |
| вход через Twitch | `?code=` (Supabase) | `/auth/twitch/callback?code=&state=` | см. 2.4 |
| стрим (чужой) | ссылка наружу | `/stream` | |

### 2.4. Вход через бэкенд

У бэкенда свой PKCE, и делит его на две стороны:

1. Страница делает `code_verifier` (43–128 знаков `[A-Za-z0-9-._~]`) и
   `code_challenge = base64url(sha256(verifier))`.
2. `GET /api/Auth/TwitchLoginState` → `{ state }`, и бэкенд ставит
   cookie с nonce.
3. Страница кладёт `verifier`, `state` и **куда вернуться** (`returnTo`
   — текущая решётка или путь) в `sessionStorage` и уводит на
   `https://id.twitch.tv/oauth2/authorize?response_type=code&client_id=…&redirect_uri=<TWITCH__REDIRECT_URI>&code_challenge=…&code_challenge_method=S256&state=…&scope=`.
4. Twitch возвращает на `/auth/twitch/callback?code=…&state=…`.
   Страница сверяет `state` с сохранённым, шлёт
   `POST /api/Auth/TwitchLogin { code, codeVerifier, state }` и получает
   `{ accessToken, refreshToken }`.
5. `history.replaceState` на `returnTo` — без `code` в адресе и без
   шага в истории.

`/auth/twitch/callback` — **один на оба фронта**: обрабатывает его
та страница, что отдаётся по этому пути, а `returnTo` уводит обратно
на базу или на стрим. Сейчас этот путь ведёт на фронтенд стрима
(`TWITCH__REDIRECT_URI=https://localhost:3000/auth/twitch/callback`);
при раскладке из 2.1 его отдаёт база, и тогда стриму достаточно
положить `returnTo=/stream`. Договориться, кто его обрабатывает, нужно
до выкладки.

Грабли, о которых лучше знать заранее:

* **Обновление токена — строго по одному на браузер.** Refresh
  одноразовый, а повтор гасит всё семейство. Две вкладки, проснувшиеся
  одновременно, обе пошлют старый refresh — вторая получит 401, и
  бэкенд выкинет человека отовсюду. Обновлять под
  `navigator.locks.request('faryma-refresh', …)` и после замка
  перечитывать токен из `localStorage`: другая вкладка могла уже
  обновить.
* **Роль в токене устаревает на срок его жизни** (до 60 минут).
  Назначили модера — увидит после обновления токена. Для мгновенного
  нужен `GetMe` (часть 3).
* **Refresh попадает под лимит `auth-login`.** Обновлять заранее
  (за минуту до `exp`), а не на каждый 401 подряд.
* **Сейчас вход — через Supabase** (`?code=` в корне, его PKCE). Два
  входа сразу — плохо: зритель залогинен в одном и гость в другом.
  Варианты — в части 4.

---

## 3. Эндпоинты

Обозначения в столбце «доступ»: **все** — без входа; **вошёл** —
любой вошедший; **админы** — `Composer` или `Moderator`;
**композитор** — `Composer`.

### 3.1. Есть в `dev` — подключаем как есть

| метод и путь | доступ | тело / параметры → ответ | зачем базе |
|---|---|---|---|
| `GET /api/Auth/TwitchLoginState` | все | → `{ state }` + cookie | кнопка «войти через Twitch» |
| `POST /api/Auth/TwitchLogin` | все | `{ code, codeVerifier, state }` → `{ accessToken, refreshToken }` | `/auth/twitch/callback` |
| `POST /api/Auth/RefreshToken` | все | `{ refreshToken }` → `{ accessToken, refreshToken }` | продление сессии, под замком |
| `POST /api/Auth/Logout` | вошёл | `{ refreshToken }` → 204 | «выйти» в настройках |
| `POST /api/Auth/LogoutAll` | вошёл | → 204 | «выйти на всех устройствах» (нового пункта в настройках) |
| `POST /api/Auth/Login` | все | `{ userName, password }` | **не наш**: вход паролем для служебных аккаунтов (`ADMIN_BOOTSTRAP__*`), из базы не зовём |
| `GET /api/ComposerStream/FindLiveAndPlanned` | все | → `{ streams: ComposerStreamDto[] }` | плашка «сейчас эфир / следующий эфир» на главной |
| `GET /api/ComposerStream/FindStreams` | все | `?DateFrom=YYYY-MM-DD&DateTo=…` → `{ streams }` | календарь эфиров, `/s/<id>` |
| `POST /api/ComposerStream/CreateStream` | композитор | `{ eventDate, type }` | «управление»: запланировать эфир |
| `POST /api/ComposerStream/StartStream` | композитор | `{ composerStreamId }` | студия: «начать эфир» |
| `POST /api/ComposerStream/CompleteStream` | композитор | `{ composerStreamId }` | студия: «новый эфир» / завершить |
| `POST /api/ComposerStream/CancelStream` | композитор | `{ composerStreamId }` | «управление» |
| `POST /api/ReviewOrder/TakeOrderInProgress` | админы | `{ reviewOrderId }` → `{ reviewOrder }` | студия: пластинка встала на проигрыватель |
| `POST /api/ReviewOrder/CompleteReviewOrder` | админы | `{ reviewOrderId, rating: 0…26 }` → `{ reviewOrder, reviewId }` | студия: пластинку положили на ступень. Сейчас это пишется в `faryma-studio-done` — отсюда и надо слать (`стСверить()`) |
| `POST /api/ReviewOrder/CreateReviewOrder` | админы | заголовок `Idempotency-Key: <guid>`; `{ nickname, orderType, trackUrl?, paymentAmount?, topUpProvider?, userComment? }` | студия: добавить трек в очередь руками |
| `POST /api/ReviewOrder/AddTrackUrl` | админы | `{ reviewOrderId, trackUrl }` | паспорт студии: поправить ссылку |
| `POST /api/ReviewOrder/MoveUpReviewOrder` | админы | `Idempotency-Key`; `{ reviewOrderId, nickname, paymentAmount, topUpProvider }` | не для базы — касса стрима |
| `POST /api/ReviewOrder/FreezeReviewOrder`, `UnfreezeReviewOrder` | админы | `{ reviewOrderId }` | студия: «в очередь» / отложить |
| `POST /api/ReviewOrder/CancelReviewOrder` | админы | `{ reviewOrderId, cancelReason }` | студия: убрать из очереди |
| `GET /api/AppSettings/GetAppSettings` | вошёл | → `{ reviewOrderNominalAmount }` | цена заказа в «хочу заказать» |
| SignalR `/api/OrderQueueNotificationHub` | все | сервер → клиент `ReceiveSnapshot(OrderQueueSnapshotMessage)`: сразу при подключении и на каждое изменение; клиент → сервер `GetSnapshot()` | очередь студии, «сейчас разносят» на главной, место своих заказов в очереди |

Снимок очереди: `{ syncVersion, orderQueueUpdateType, activeOrders[],
inProgressOrder?, completedOrders[], scheduledOrders[], frozenOrders[] }`,
элемент — `{ order: ReviewOrderDto, currentPosition, previousPosition,
isPositionChanged, isOrderUpdated }`. Библиотеку `@microsoft/signalr`
грузить так же, как Supabase: последней и необязательной — не доехала,
нет очереди, остальное работает.

`ReviewOrderDto` — `id, createdAt, inProgressAt, completedAt, type,
status, isFrozen, trackUrl, userComment, mainNickname, totalAmount,
creationStream`. **Названия, исполнителя и обложки в нём нет** — только
ссылка. Студии придётся, как и сейчас, узнавать трек по ссылке
(oEmbed, `coverOf`) — или ждать `GetTrackByUrl` из 3.2.

### 3.2. Нужно добавить — без этого базу не подключить

Имена — в стиле бэкенда (`api/<Контроллер>/<Действие>`). Это
предложение, а не готовый контракт: поля сверить с тем, кто пишет
бэкенд.

**Каталог (`Track`).** Сейчас каталог — `full.csv`, `years.json`,
`countries.json` из репозитория статистики.

| метод и путь | доступ | что отдаёт / делает | заменяет у нас |
|---|---|---|---|
| `GET /api/Track/GetCatalog` | все | весь каталог одной выгрузкой в сжатом виде + `ETag`; на `If-None-Match` — 304 | `full.csv` + `years.json` + `countries.json`. Именно весь: отбор, счётчики рельса и «похожие» считаются на странице по всем 7 тыс. строк, постраничная выдача их не прокормит |
| `GET /api/Track/GetTrack` | все | `?trackId` → трек целиком: исполнители, жанры и расширенные жанры, тэги, страна, дата выпуска, длительность, обложка, ссылки, все разносы (`Review` + эфир + ник заказчика), факты, «о чём трек» | строку каталога на странице трека |
| `GET /api/Track/GetTrackByUrl` | все | `?url` → трек, если совпал **сам id** ролика / трека Spotify (не похожее имя — правило из CLAUDE.md) | `вАрхивеПоСсылке()`, узнавание в студии |
| `GET /api/Track/GetDictionaries` | все | жанры, страны, тэги, вселенные, «происхождение», «тип трека» — с написанием таблицы | словари рельса и паспорта студии |
| `POST /api/Track/UpdateTrack` | админы | жанры, тэги, страна, год, обложка, факты, «о чём трек» | паспорт студии, панель `#covers` (вместо ручной сборки `covers.json`/`facts.json`) |

Чего для этого не хватает в схеме (`TrackEntity` и соседи):

* **Ссылки по площадкам.** Сейчас одна `Url`; нужны YouTube, Spotify
  (`sid`), Яндекс и запись ВК раздельно — плеер оригинала показывает
  только те, что есть.
* **Происхождение по году и обложке.** Дата выпуска и обложка
  годятся, только если трек найден по ссылке или совпадение прошло
  `YEAR_MIN_SCORE`. Без поля «откуда и насколько надёжно» бэкенд
  станет показывать чужие года — то, от чего база уже лечилась.
* «Три интересных факта», «О чём трек?», уточнение в скобках, альбом,
  вселенная, происхождение, тип трека.
* **`CompleteReviewOrder` к треку не привязывает.**
  `ReviewStore.Create(order, rating, user)` оставляет `Review.TrackId`
  пустым, а `Track` не создаёт никто. Пока это так, разнос в каталог
  не попадёт.

**Эфиры и разносы.**

| метод и путь | доступ | что | зачем |
|---|---|---|---|
| `GET /api/ComposerStream/GetStream` | все | `?composerStreamId` → эфир с его разносами | `/s/<id>`, «итог эфира» студии |
| `GET /api/Review/FindReviews` | все | `?trackId` или `?composerStreamId` | разносы трека и эфира |
| `POST /api/Review/UpdateReview` | композитор | `{ reviewId, rating?, timestampUrl? }` | переоценка после штампа; тайм-код записи |

В `ComposerStreamEntity` нет **номера эфира** (у нас «эфир №282» — в
шапке трека, в «Инфо», в ключе трека) и **ссылки на запись** ВК. Без
номера не собрать ключ, по которому живут все нынешние ссылки на треки.

**Оценки зрителей (`UserTrackRating`).** Сущность уже есть; сейчас
это `ratings` в Supabase.

| метод и путь | доступ | что | заменяет |
|---|---|---|---|
| `GET /api/UserTrackRating/GetMyRatings` | вошёл | все свои оценки с `updatedAt` | сверка `сверитьВсё()` |
| `POST /api/UserTrackRating/SetRating` | вошёл | `{ trackId, rating, ratedAt }`, upsert; время ставит сервер, `ratedAt` из будущего срезается | щелчок по шкале, `оценкаНаСервер()` |
| `GET /api/UserTrackRating/GetTrackRatings` | все | `?trackId` → открытые голоса | «оценки зрителей» |
| `GET /api/UserTrackRating/GetAverages` | все | средняя и число голосов по всем трекам | `track_avgs` |
| `GET /api/UserTrackRating/GetUserRatings` | все | `?login` → открытые оценки | оценки в чужом профиле |

Удаления оценки не нужно — кнопки «убрать мою оценку» нет по просьбе
заказчика. Нужна галочка «показывать мои оценки» (поле профиля),
иначе открытость не на чем держать.

**Пользователь.**

| метод и путь | доступ | что | заменяет |
|---|---|---|---|
| `GET /api/User/GetMe` | вошёл | id, логин и **отображаемое имя** Twitch, аватар, роли, дата первого входа, привязанные ники, настройки приватности | `profiles` своей строкой, `штатСайта()` |
| `POST /api/User/UpdateMe` | вошёл | цвет, «о себе», галочки приватности, свой ник | `profiles` + `set_name()` |
| `GET /api/User/GetUser` | все | `?login` → открытый профиль | `#u=` |
| `POST /api/User/DeleteMe` | вошёл | удалить аккаунт со всем | `delete_me()` |
| `GET /api/User/ListRoles`, `POST /api/User/GrantRole` | композитор (модеров — и админ) | команда сайта | `list_roles`, `grant_role` |

Сейчас бэкенд хранит только `TwitchLogin`: ни отображаемого имени, ни
аватара. `TwitchLogin` берёт их из `oauth2/validate`, а там их нет —
нужен ещё запрос `GET https://api.twitch.tv/helix/users` тем же
токеном при входе.

**Ники и свои заказы.** `UserNicknameEntity.UserId` — ровно наши
`claims`: ник из колонки «Кто», привязанный к аккаунту. Ники бэкенд
уже нормализует (`NormalizedNickname`), а у заказа их несколько
(совместный «A; B») — как у нас.

| метод и путь | доступ | что | заменяет |
|---|---|---|---|
| `GET /api/UserNickname/FindNicknames` | вошёл | `?prefix` → ники по началу слова с числом заказов и «уже привязан» | подсказки во вкладке «заявки» |
| `POST /api/UserNickname/RequestClaim` | вошёл | `{ nickname }` | заявка на привязку |
| `GET /api/UserNickname/GetMyClaims` | вошёл | свои заявки | |
| `GET /api/UserNickname/FindPendingClaims` | админы | ждущие + для сверки: ник и канал, первый вход, последние заказы ника | разбор заявок |
| `POST /api/UserNickname/ResolveClaim` | админы | `{ claimId, approve }`; один ник — одному аккаунту | |
| `POST /api/UserNickname/Unlink` | админы | снять привязку | |
| `GET /api/ReviewOrder/FindOrders` | все | `?nickname` или `?userLogin` → заказы с разносом и треком | «мои заказы», «заказал» на странице трека, чужой профиль |

Роли: у нас `owner` / `admin` / `moder`, в бэкенде — `Composer` /
`Moderator`. `owner` ложится на `Composer`; а `admin` и `moder`
бэкенд не различает, и его `Moderator` может всё с заказами
(`AuthorizeAdmins`). У нас модеру студия закрыта. Нужна третья роль —
или договориться, что у нас `admin` = их `Moderator`, а наш `moder` в
бэкенде — просто вошедший.

### 3.3. Остаётся в Supabase

Комментарии и рецензии (`comments`, `comment_likes`), сердечки
(`favs`), подписки, «на сайте сейчас» (`online`), уведомления,
сообщения о неточностях (`reports`), «хочу заказать» (`wishes`),
плейлисты, топ по опыту. В бэкенде им соответствия нет, и пока его
нет, переносить их некуда. Чтобы связать одно с другим, хватит
**Twitch user id**: в бэкенде он `UserEntity.TwitchUserId`, в Supabase
— `provider_id` в данных Twitch у `auth.users`.

`UserTrackRating.Comment` (комментарий при оценке) нашими комментариями
**не** заменить: у нас ответы ветками, лайки, рецензии и правила длины.

---

## 4. Что решить до начала

1. **Чей корень и чей `/auth/twitch/callback`** (2.1, 2.4). От этого
   зависит `TWITCH__REDIRECT_URI` и путь к базе.
2. **Один вход или два.** Варианты:
   а) переносим вход на бэкенд, Supabase остаётся для «социального» и
   узнаёт пользователя по Twitch id — тогда нужен мост между токенами
   (как именно — проверить по документации Supabase на момент работ,
   правила доступа в `schema.sql` держатся на `auth.uid()`);
   б) пока оставляем вход через Supabase, а от бэкенда берём только
   открытое (каталог, эфиры, очередь), без входа. Студию тогда водит
   десктоп-клиент бэкенда или вход паролем.
   Предлагаю б) на первый шаг: он ничего не ломает, и зрители ничего не
   замечают.
3. **Шкала оценки.** `CompleteReviewOrder` принимает `rating` от 0 до 26
   — это 27 значений. В архиве точных оценок 26. Узнать, что значит
   0 и в какую сторону растёт шкала, и записать соответствие.
4. **Кто переносит архив** (8 тыс. строк `full.csv`, года и обложки из
   `years.json`) в таблицы `Track*` — и с какими порогами доверия.

## 5. Мелочи в бэкенде, замеченные по пути

* `POST /api/AppSettings/UpdateAppSettings` стоит под `[Authorize]`, а
  не `[AuthorizeComposer]`: менять цену заказа может **любой вошедший**
  через Twitch. А войти может кто угодно: `TwitchLogin` заводит
  пользователя на первый вход сам. Это стоит поправить до выкладки.
* `ReviewService` пустой — заготовка под разносы.
* Без `UseForwardedHeaders` лимит входа за прокси один на всех (2.1).
