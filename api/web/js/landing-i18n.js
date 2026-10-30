(() => {
    const storageKey = 'viewvee.landingLocale.v2';
    const localeNames = {
        ar: 'العربية',
        cs: 'Čeština',
        da: 'Dansk',
        de: 'Deutsch',
        en: 'English',
        es: 'Español',
        fi: 'Suomi',
        fr: 'Français',
        hr: 'Hrvatski',
        hu: 'Magyar',
        id: 'Bahasa Indonesia',
        it: 'Italiano',
        ja: '日本語',
        ko: '한국어',
        nb: 'Norsk',
        nl: 'Nederlands',
        pl: 'Polski',
        pt: 'Português',
        ro: 'Română',
        ru: 'Русский',
        sk: 'Slovenčina',
        sv: 'Svenska',
        th: 'ไทย',
        tr: 'Türkçe',
        uk: 'Українська',
        vi: 'Tiếng Việt',
        zh: '简体中文',
        zh_Hant: '繁體中文',
    };

    const translations = {
        en: {
            metaTitle: 'ViewVee · Stay close from anywhere',
            metaDescription: 'ViewVee turns two phones into a private camera and monitor for the people, pets, and places that matter.',
            mainNavigation: 'Main navigation',
            language: 'Language',
            features: 'Features',
            howItWorks: 'How it works',
            support: 'Support',
            logoAlt: 'ViewVee logo',
            badge: 'Private monitoring with devices you already own',
            heroTitlePrefix: 'Stay close to what',
            heroTitleHighlight: 'matters most.',
            heroBody: 'Turn one phone into a secure camera and another into a live monitor. Watch over your baby, pet, or home on Wi-Fi or from anywhere.',
            seeHowItWorks: 'See how it works',
            contactSupport: 'Contact support',
            encryptedWebrtc: 'Encrypted WebRTC',
            localWifiMode: 'Local Wi-Fi mode',
            iosAndroid: 'iOS & Android',
            nurseryCamera: 'Nursery camera',
            connectedSecurely: 'Connected securely',
            live: 'LIVE',
            privateVideoStream: 'Private video stream',
            endToEndEncryption: 'End-to-end media encryption',
            video: 'Video',
            latency: 'Latency',
            battery: 'Battery',
            featuresEyebrow: 'Made for peace of mind',
            featuresTitle: 'A simple monitor with serious privacy.',
            featuresBody: 'Fast pairing, clear video, and useful alerts without buying another single-purpose device.',
            secureByDesign: 'Secure by design',
            secureByDesignBody: 'Pair devices with a private QR secret. Signaling is authenticated and media travels over encrypted WebRTC.',
            nearOrFar: 'Near or far',
            nearOrFarBody: 'Connect directly on the same Wi-Fi, or use secure internet relay when the two phones are on different networks.',
            knowWhenItMatters: 'Know when it matters',
            knowWhenItMattersBody: 'Receive motion, sound, and connection alerts. Monitor battery status and record important moments locally.',
            stepsEyebrow: 'Ready in minutes',
            stepsTitle: 'Two phones. One secure connection.',
            stepsBody: 'ViewVee guides you through every step, from choosing a role to starting the live view.',
            chooseRoles: 'Choose roles',
            chooseRolesBody: 'Use one device as the camera and another as the monitor.',
            scanToPair: 'Scan to pair',
            scanToPairBody: 'Connect securely with a private QR code or pairing flow.',
            startWatching: 'Start watching',
            startWatchingBody: 'See, listen, talk, and receive alerts wherever you are.',
            faqEyebrow: 'Frequently asked questions',
            faqTitle: 'Everything you need to get started.',
            faqDevicesQuestion: 'Do I need two phones?',
            faqDevicesAnswer: 'Yes. One phone works as the camera and another as the monitor. An older spare phone is perfect for the camera.',
            faqRemoteQuestion: 'Can I watch from outside my home Wi-Fi?',
            faqRemoteAnswer: 'Yes. ViewVee connects directly when both phones share a Wi-Fi network and uses a secure internet relay when they are on different networks.',
            faqPrivacyQuestion: 'Is my video private?',
            faqPrivacyAnswer: 'Devices pair using a private QR secret. Signaling is authenticated and your media travels over encrypted WebRTC.',
            faqPlatformsQuestion: 'Can I pair an iPhone with an Android phone?',
            faqPlatformsAnswer: 'Yes. ViewVee supports iOS and Android, including pairing devices across the two platforms.',
            faqRecordingsQuestion: 'Where are recordings saved?',
            faqRecordingsAnswer: 'Recordings are saved locally on the device that captured them, so you stay in control of your recorded moments.',
            contactEyebrow: 'ViewVee support',
            contactTitle: 'How can we help?',
            contactBody: 'Send us a message and our support team will reply by email.',
            contactName: 'Name',
            contactEmail: 'Email',
            contactSubject: 'Subject',
            contactMessage: 'Message',
            contactSubmit: 'Send message',
            contactSending: 'Sending…',
            contactSuccess: 'Thanks. Your message was sent to ViewVee support.',
            contactError: 'The message could not be sent. Please try again or email us directly.',
            ctaTitle: 'Keep an eye on what you love.',
            ctaBody: 'ViewVee gives your spare phone a meaningful second life—and gives you a clearer view when you cannot be in the room.',
            talkToSupport: 'Talk to ViewVee support',
            privacy: 'Privacy',
            terms: 'Terms',
            deleteData: 'Delete data',
            deleteAccount: 'Delete account',
        },
    };

    function register(localeTranslations) {
        Object.assign(translations, localeTranslations);
    }

    function normalizeLocale(locale) {
        const normalized = locale.replaceAll('-', '_');
        if (/^zh_(Hant|TW|HK|MO)/i.test(normalized)) return 'zh_Hant';
        const language = normalized.split('_')[0].toLowerCase();
        return Object.hasOwn(localeNames, language) ? language : null;
    }

    function deviceLocale() {
        for (const locale of navigator.languages || [navigator.language]) {
            const match = normalizeLocale(locale);
            if (match) return match;
        }
        return 'en';
    }

    function preferredSelection() {
        try {
            const saved = localStorage.getItem(storageKey);
            if (saved && Object.hasOwn(localeNames, saved)) return saved;
        } catch (_) {
            // Storage can be unavailable in privacy-restricted browser contexts.
        }
        return 'auto';
    }

    function message(locale, key) {
        return translations[locale]?.[key] ?? translations.en[key] ?? key;
    }

    function applyLocale(locale, selection = locale) {
        const selected = translations[locale] ? locale : 'en';
        const htmlLocale = selected === 'zh_Hant' ? 'zh-Hant' : selected;
        document.documentElement.lang = htmlLocale;
        document.documentElement.dir = selected === 'ar' ? 'rtl' : 'ltr';
        document.title = message(selected, 'metaTitle');
        document.querySelector('meta[name="description"]')?.setAttribute('content', message(selected, 'metaDescription'));
        document.querySelector('meta[property="og:title"]')?.setAttribute('content', message(selected, 'metaTitle'));
        document.querySelector('meta[property="og:description"]')?.setAttribute('content', message(selected, 'metaDescription'));
        const screenshotVersion = '20260902-complete';
        const setupScreenshotPath = `/images/app-setup-${selected}.png?v=${screenshotVersion}`;
        const roleScreenshotPath = `/images/app-real-role-${selected}-dark.png?v=${screenshotVersion}`;
        document.querySelector('meta[property="og:image"]')?.setAttribute('content', setupScreenshotPath);
        const setupScreenshot = document.getElementById('app-setup-screenshot');
        if (setupScreenshot) {
            setupScreenshot.src = setupScreenshotPath;
            setupScreenshot.alt = `ViewVee · ${message(selected, 'featuresTitle')}`;
        }
        const roleScreenshot = document.getElementById('app-role-screenshot');
        if (roleScreenshot) {
            roleScreenshot.onerror = () => {
                roleScreenshot.onerror = null;
                roleScreenshot.src = `/images/app-real-role-en-dark.png?v=${screenshotVersion}`;
            };
            roleScreenshot.src = roleScreenshotPath;
            roleScreenshot.alt = `ViewVee · ${message(selected, 'chooseRoles')}`;
        }
        document.querySelectorAll('[data-i18n]').forEach((element) => {
            element.textContent = message(selected, element.dataset.i18n);
        });
        document.querySelectorAll('[data-i18n-aria-label]').forEach((element) => {
            element.setAttribute('aria-label', message(selected, element.dataset.i18nAriaLabel));
        });
        document.querySelectorAll('[data-i18n-alt]').forEach((element) => {
            element.setAttribute('alt', message(selected, element.dataset.i18nAlt));
        });
        const select = document.getElementById('language-select');
        if (select) select.value = selection === 'auto' ? 'auto' : selected;
        const languageCode = document.getElementById('language-code');
        if (languageCode) {
            languageCode.textContent = selected === 'zh_Hant' ? 'ZH-T' : selected.toUpperCase();
        }
    }

    function initialize() {
        const select = document.getElementById('language-select');
        if (select) {
            const detectedLocale = deviceLocale();
            select.add(new Option(`Auto · ${localeNames[detectedLocale]}`, 'auto'));
            for (const [locale, name] of Object.entries(localeNames)) {
                select.add(new Option(name, locale));
            }
            select.addEventListener('change', () => {
                try {
                    if (select.value === 'auto') {
                        localStorage.removeItem(storageKey);
                    } else {
                        localStorage.setItem(storageKey, select.value);
                    }
                } catch (_) {
                    // Applying a language does not depend on persistence.
                }
                const selectedLocale = select.value === 'auto' ? deviceLocale() : select.value;
                applyLocale(selectedLocale, select.value);
            });
        }
        const preferred = preferredSelection();
        applyLocale(preferred === 'auto' ? deviceLocale() : preferred, preferred);
    }

    window.ViewVeeLandingI18n = { register };
    if (document.readyState === 'complete') {
        initialize();
    } else {
        document.addEventListener('DOMContentLoaded', initialize, { once: true });
    }
})();