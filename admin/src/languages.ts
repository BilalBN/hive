/** Languages Hive knows by name (the same list as the server's languages.py). */
export const LANGUAGES: { code: string; name: string; native: string }[] = [
  { code: "ml", name: "Malayalam", native: "മലയാളം" },
  { code: "hi", name: "Hindi", native: "हिन्दी" },
  { code: "ta", name: "Tamil", native: "தமிழ்" },
  { code: "te", name: "Telugu", native: "తెలుగు" },
  { code: "kn", name: "Kannada", native: "ಕನ್ನಡ" },
  { code: "bn", name: "Bengali", native: "বাংলা" },
  { code: "pa", name: "Punjabi", native: "ਪੰਜਾਬੀ" },
  { code: "gu", name: "Gujarati", native: "ગુજરાતી" },
  { code: "mr", name: "Marathi", native: "मराठी" },
  { code: "ur", name: "Urdu", native: "اردو" },
  { code: "sa", name: "Sanskrit", native: "संस्कृतम्" },
  { code: "en", name: "English", native: "English" },
  { code: "ar", name: "Arabic", native: "العربية" },
  { code: "fr", name: "French", native: "Français" },
  { code: "es", name: "Spanish", native: "Español" },
  { code: "ko", name: "Korean", native: "한국어" },
  { code: "ja", name: "Japanese", native: "日本語" },
  { code: "zxx", name: "Instrumental", native: "Instrumental" },
];

export function languageName(code?: string | null): string | undefined {
  if (!code) return undefined;
  return LANGUAGES.find((l) => l.code === code)?.name ?? code;
}
