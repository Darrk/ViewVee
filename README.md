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

Internet build lze nakonfigurovat pomoci `--dart-define`:

```sh
flutter run \
	--dart-define=VIEWVEE_SIGNALING_URL=wss://signal.viewvee.com/viewvee/ws \
	--dart-define=VIEWVEE_STUN_URLS=stun:stun.example.com:3478 \
	--dart-define=VIEWVEE_TURN_URL=turns:turn.viewvee.com:5349 \
	--dart-define=VIEWVEE_TURN_USERNAME=user \
	--dart-define=VIEWVEE_TURN_CREDENTIAL=credential
```

Signal server `wss://signal.viewvee.com/viewvee/ws` a TURN server
`turns:turn.viewvee.com:5349` jsou vychozi, takze jejich URL neni nutne
predavat. Pro spojeni telefonu v ruznych sitich je produkcni TURN povinny. Pri
release build procesu predejte `VIEWVEE_TURN_USERNAME` a
`VIEWVEE_TURN_CREDENTIAL` z CI nebo backendu a neukladejte je do repozitare.

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
Registry, region, repozitář, tag a platformy lze změnit proměnnými
`AWS_ACCOUNT_ID`, `AWS_REGION`, `ECR_REPOSITORY`, `IMAGE_TAG` a `PLATFORMS`.

## Deployment to AppStore (iOS)

flutter build ipa --obfuscate --split-debug-info=build/app/outputs/symbols && ./ios/Pods/FirebaseCrashlytics/upload-symbols -ai 1:742142459888:ios:f4b3f0ecc0737d8350a735 --platform ios -- ./build/app/outputs/

## Deployment to Google Play (Android)

flutter build appbundle --obfuscate --split-debug-info=build/app/outputs/symbols && firebase crashlytics:symbols:upload --app=1:742142459888:android:a068937b3b88140850a735 build/app/outputs/symbols
