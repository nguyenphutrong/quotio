import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';
import en from '@/i18n/locales/en.json';
import vi from '@/i18n/locales/vi.json';
import zh from '@/i18n/locales/zh.json';

const STORAGE_KEY = 'quotio-language';

function getInitialLanguage(): string {
  const stored = localStorage.getItem(STORAGE_KEY);
  if (stored && ['en', 'vi', 'zh'].includes(stored)) {
    return stored;
  }
  const browserLang = navigator.language.split('-')[0];
  if (browserLang && ['en', 'vi', 'zh'].includes(browserLang)) {
    return browserLang;
  }
  return 'en';
}

void i18n.use(initReactI18next).init({
  resources: {
    en: { translation: en },
    vi: { translation: vi },
    zh: { translation: zh },
  },
  lng: getInitialLanguage(),
  fallbackLng: 'en',
  interpolation: {
    escapeValue: false,
  },
});

i18n.on('languageChanged', (lng) => {
  localStorage.setItem(STORAGE_KEY, lng);
  document.documentElement.lang = lng;
});

export default i18n;
