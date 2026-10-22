# Viewvee

Mobilni kamera a monitor pro Android a iOS. Jeden telefon vysila video a zvuk,
druhy zobrazuje prenos a muze zapnout obousmerny hovor.

## Prenos

- **Stejna Wi-Fi:** Bonjour/mDNS najde kameru a signaling probiha pres TCP v
  lokalni siti.
- **Internet:** signaling probiha pres WSS relay; WebRTC pouziva STUN a volitelne
  TURN.
- QR kod obsahuje 256bit pairing secret. Sestimistny kod je pouze verejny
  identifikator a sam o sobe nestaci k pripojeni.
- Signaling zpravy jsou chranene HMAC, poradovym cislem a ochranou proti replay.
  Media prenasi sifrovane WebRTC.

## Spusteni

```sh
flutter pub get
flutter run
```

### Debug na fyzickem zarizeni ve VS Code

1. Pripojte Android telefon pres USB, zapnete USB debugging v nastaveni pro
   vyvojare a na telefonu povolte pristup tomuto pocitaci.
2. Overte, ze telefon zobrazuje `flutter devices` (pri potizich spustte
   `flutter doctor -v`).
3. Ve VS Code spustte **Flutter: Select Device** a vyberte telefon.
4. V panelu Run and Debug vyberte **ViewVee (Physical Device)** a stisknete F5.
   Konfigurace pouziva vybrane zarizeni a podporuje breakpointy a hot reload.
   **ViewVee (Android Emulator)** nadale spousti emulator `Pixel_7_API_36`.

Pro fyzicky iPhone pouzijte stejnou konfiguraci na macOS s Xcode, pripojenym
a duveryhodnym telefonem a nastavenym signing teamem v `ios/Runner.xcworkspace`.

V rezimu kamery na Androidu tlacitko **Spustit na pozadi** nejprve zajisti
foreground service pro kameru a mikrofon a pak presune aplikaci na pozadi.
Tlacitko je dostupne po spusteni kamery, i pri cekani na monitor. Klepnutim
na trvale oznameni se vratite do aplikace. Pokud service nelze spustit,
aplikace zustane otevrena a zobrazi chybu. Tato funkce je pouze pro Android.

### Obnoveni spojeni

Kamera uchovava parovaci udaje v secure storage zvlast pro Wi-Fi a internet.
Po restartu aplikace se obnovi posledni role a zpusob pripojeni; monitor
pouzije ulozeny parovaci odkaz a po vypadku opakuje pripojeni automaticky
s prodlevou nejvyse 15 sekund mezi pokusy. Nove skenovani QR kodu neni po
beznem restartu kamery potreba. Opusteni role kamery/monitoru automaticke
obnovovani zastavi. Odhlaseni smaze ulozene parovaci udaje.

Po aktualizaci ze starsi verze aplikace sparujte zarizeni jednou znovu:
starsi verze parovaci udaje kamery neuchovavala.

Internet build lze nakonfigurovat pomoci `--dart-define`:

```sh
flutter run \
  --dart-define=VIEWVEE_SIGNALING_URL=wss://signal.viewvee.com/viewvee/ws \
  --dart-define=VIEWVEE_TURN_CREDENTIALS_URL=https://viewvee.com/api/turn/credentials \
  --dart-define=VIEWVEE_AUTH_SCOPES="openid email profile offline_access viewvee-api"
```

Signal server a URL credential endpointu vyse jsou vychozi. TURN URL a expiraci
urcuje API. Aplikace posila IdentityServer access token a pred kazdym novym
internetovym spojenim i reconnectem ziska cerstve TURN credentials. Nepouzivejte
build-time `VIEWVEE_TURN_USERNAME` / `VIEWVEE_TURN_CREDENTIAL`; sdileny TURN
secret patri pouze na backend. Lokalni Wi-Fi pripojeni credential endpoint nevola.
Nasazeni endpointu a nastaveni IdentityServeru popisuje [api/README.md](api/README.md).

## Platformy

iOS vyzaduje deployment target 15.5. Projekt obsahuje popisy opravneni pro
kameru, mikrofon a lokalni sit a deklaraci Bonjour sluzby `_viewvee._tcp`.

Android vyzaduje SDK, JDK 17 a opravneni pro kameru, mikrofon, foreground
service a multicast discovery. Application/bundle ID je
`com.specterint.viewvee`. Pred publikaci je nutne nastavit release signing.

## Autentizace

Viewvee pouziva stejny identity tok jako Working Timer: secure storage, silent
refresh, prihlaseni, registraci, odhlaseni a externi Apple, Facebook a Google
providery pres OAuth 2.1 Authorization Code + PKCE. Aplikace nepodporuje anonymni
ani hostovsky pristup.

Pro beh nastavte `VIEWVEE_IDENTITY_URL`, `VIEWVEE_AUTH_CLIENT_ID`,
`VIEWVEE_AUTH_CLIENT_SECRET` a volitelne `VIEWVEE_AUTH_SCOPES` pomoci
`--dart-define`. OAuth klient na identity serveru musi povolit redirect URI
`viewvee://oauth/callback` a providery `Apple`, `Facebook` a `Google`. Client
secret z Working Timeru se nesmi kopirovat ani commitovat; Viewvee potrebuje
vlastni registraci klienta.

## Pravni dokumenty

Pravni dokumenty pro publikaci jsou v `api/web/privacy-policy.html` a
`api/web/terms-of-use.html`. Aplikace odkazuje na jejich produkcni adresy
`https://viewvee.com/privacy-policy.html` a
`https://viewvee.com/terms-of-use.html`. Verejne informace o smazani dat jsou
na `https://viewvee.com/account/data-delete`; prihlaseny uzivatel smaze ucet
pres `https://viewvee.com/account/delete`.

## Overeni

```sh
flutter test
flutter analyze
flutter build ios --simulator
flutter build apk --debug
```

Pred vydanim otestujte iOS-iOS, Android-Android a iOS-Android na fyzickych
telefonech ve stejne Wi-Fi i v oddelenych sitich pres TURN.

## Web a požadavky na smazání dat

Produkční web obsluhuje Go server na portu `8080`. Server poskytuje statické
webové soubory, zdravotní kontrolu `/healthz` a formuláře `/account/delete` a
`/account/data-delete`. Požadavky se posílají podpoře přes SMTP a před smazáním
je nutné ověřit vlastníka účtu. Sestavení webového kontejneru nekompiluje
Flutter aplikaci.

Landing page a formuláře používají předkompilovaný Tailwind stylesheet
`api/web/css/tailwind.css`. Po změně Tailwind tříd jej obnovte příkazem:

```sh
cd api && npx --yes tailwindcss@3.4.17 -c tailwind.config.js \
  -i tailwind.css -o web/css/tailwind.css --minify
```

Formuláře odesílají e-mail přes AWS SES SMTP na pevnou adresu
`support@specterint.com`. Výchozí server je
`email-smtp.eu-central-1.amazonaws.com:587` s TLS a odesílatel
`ViewVee Support <info@specterint.com>`. Nasazení musí dodat přihlašovací údaje
`SMTP_USERNAME` a `SMTP_PASSWORD`. Volitelně lze změnit `SMTP_HOST`,
`SMTP_PORT`, `SMTP_FROM` a `SMTP_FROM_NAME`. Obraz sestavíte a odešlete do AWS
ECR pomocí:

```sh
./build.sh
```

Skript ve výchozím nastavení publikuje víceplatformový obraz
`139685415139.dkr.ecr.eu-central-1.amazonaws.com/specterint/viewvee-web:latest`.
Bez argumentů nyní publikuje také `specterint/viewvee-signal` a
`specterint/viewvee-turn`. Pro jednotlivé služby použijte `./build.sh web`,
`./build.sh signaling` nebo `./build.sh turn`. Registry, region, repozitáře,
tag a platformy lze změnit proměnnými `AWS_ACCOUNT_ID`, `AWS_REGION`,
`ECR_REPOSITORY` (web), `SIGNAL_ECR_REPOSITORY`, `TURN_ECR_REPOSITORY`,
`IMAGE_TAG` a `PLATFORMS`.

## Sdílená signaling a TURN infrastruktura

ViewVee je hlavní správce infrastruktury používané ViewVee i BabyWave:

- [`api/signaling-server`](api/signaling-server/README.md): samostatný Go WebSocket
  relay pro `/viewvee/ws` i `/baby-monitor/ws`, se společnými rooms a `/healthz`.
- [`api/turn-server`](api/turn-server/README.md): samostatný coturn server,
  konfigurace a Docker Compose pro `turn.viewvee.com`.
- `api/nginx.conf`: reverse proxy pro `signal.viewvee.com`; upstream `backend:8080`
  musí směřovat na signaling kontejner, nikoli na webový server.

Služby jsou nasazované odděleně od webu; signaling i web používají interní port
8080 ve vlastních kontejnerech. Změna umístění nemění protokol ani produkční
image názvy. ViewVee web/API poskytuje autentizovaný endpoint
`GET /api/turn/credentials` pro scope a audience `viewvee-api`; jeho
`TURN_SHARED_SECRET` musí odpovídat coturn konfiguraci. BabyWave může nadále
používat vlastní endpoint se stejným coturn secretem.

```sh
(cd api && go test ./...)
(cd api/signaling-server && go test -race ./...)
```

## Deployment to AppStore (iOS)

flutter build ipa --obfuscate --split-debug-info=build/app/outputs/symbols && ./ios/Pods/FirebaseCrashlytics/upload-symbols -ai 1:742142459888:ios:f4b3f0ecc0737d8350a735 --platform ios -- ./build/app/outputs/

## Deployment to Google Play (Android)

flutter build appbundle --obfuscate --split-debug-info=build/app/outputs/symbols && firebase crashlytics:symbols:upload --app=1:742142459888:android:a068937b3b88140850a735 build/app/outputs/symbols
