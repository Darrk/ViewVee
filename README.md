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
	--dart-define=VIEWVEE_SIGNALING_URL=wss://signal.example.com/viewvee/ws \
	--dart-define=VIEWVEE_STUN_URLS=stun:stun.example.com:3478 \
	--dart-define=VIEWVEE_TURN_URL=turns:turn.example.com:5349 \
	--dart-define=VIEWVEE_TURN_USERNAME=user \
	--dart-define=VIEWVEE_TURN_CREDENTIAL=credential
```

Pro spojeni telefonu v ruznych sitich je produkcni TURN povinny. Pri release
build procesu predejte TURN udaje z CI nebo backendu a neukladejte je do
repozitare.

## Platformy

iOS vyzaduje deployment target 15.5. Projekt obsahuje popisy opravneni pro
kameru, mikrofon a lokalni sit a deklaraci Bonjour sluzby `_viewvee._tcp`.

Android vyzaduje SDK, JDK 17 a opravneni pro kameru, mikrofon, foreground
service a multicast discovery. Pred publikaci je nutne nahradit vyvojove
`com.example.viewvee` vlastnim application/bundle ID a nastavit release signing.

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

## Overeni

```sh
flutter test
flutter analyze
flutter build ios --simulator
flutter build apk --debug
```

Pred vydanim otestujte iOS-iOS, Android-Android a iOS-Android na fyzickych
telefonech ve stejne Wi-Fi i v oddelenych sitich pres TURN.
