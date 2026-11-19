import 'dart:ui';

/// Testi dell'app. Italiano di default, inglese se il sistema è in un'altra lingua.
class S {
  S._(this.it);

  final bool it;

  static final S current = S._(
    PlatformDispatcher.instance.locale.languageCode == 'it' || PlatformDispatcher.instance.locale.languageCode.isEmpty,
  );

  String t(String itText, String enText) => it ? itText : enText;

  String get tagline => t('Foto pronte per il web', 'Photos ready for the web');
  String get dropTitle => t('Trascina qui\nle foto', 'Drop your\nphotos here');
  String get dropHint => t(
    'JPG, PNG, WebP, TIFF. Anche quelle da 8 MB che ti manda il cliente.',
    'JPG, PNG, WebP, TIFF. Even the 8 MB ones your client sends you.',
  );
  String get dropActive => t('Lasciale andare', 'Let them go');
  String get chooseFiles => t('Scegli file', 'Choose files');
  String get clear => t('Svuota', 'Clear');
  String photos(int n) => n == 1 ? t('1 foto', '1 photo') : t('$n foto', '$n photos');

  String get settings => t('Impostazioni', 'Settings');
  String get keyword => t('Parola chiave', 'Keyword');
  String get keywordHint => t('es. agriturismo todi camera doppia', 'e.g. tuscany farmhouse double room');
  String get keywordHelp => t(
    'Diventa il nome dei file. Vuota: si usa il nome originale ripulito.',
    'Becomes the file name. Empty: the cleaned original name is used.',
  );
  String get format => t('Formato', 'Format');
  String get quality => t('Qualità', 'Quality');
  String get widths => t('Larghezze', 'Widths');
  String get widthsHelp => t(
    'Non ingrandisce mai: le foto più piccole restano alla loro misura.',
    'Never upscales: smaller photos keep their size.',
  );
  String get addWidth => t('Aggiungi', 'Add');
  String get outputFolder => t('Cartella di uscita', 'Output folder');
  String get outputDefault => t('Accanto alle foto, in "snella-web"', 'Next to the photos, in "snella-web"');
  String get change => t('Cambia', 'Change');
  String get extras => t('Extra', 'Extras');
  String get csv => t('CSV con nomi, pesi e alt', 'CSV with names, sizes and alt');
  String get srcset => t('Snippet HTML con srcset', 'HTML snippet with srcset');
  String get alwaysStripped => t('EXIF e GPS rimossi sempre', 'EXIF and GPS always removed');

  String get run => t('Rendile snelle', 'Slim them down');
  String working(int done, int total) => t('Lavoro… $done di $total', 'Working… $done of $total');
  String get addPhotosFirst => t('Prima aggiungi le foto', 'Add some photos first');

  String get resultsTitle => t('Fatto.', 'Done.');
  String fromTo(String from, String to) => t('Da $from a $to', 'From $from to $to');
  String saved(int pct) => t('−$pct% di peso', '−$pct% weight');
  String filesCreated(int n) => t('$n file creati', '$n files created');
  String get openFolder => t('Apri cartella', 'Open folder');
  String get startOver => t('Nuovo lotto', 'New batch');
  String get errorUnreadable => t('Formato non leggibile', 'Unreadable format');
  String get errorGeneric => t('Errore', 'Error');
  String failed(int n) => t('$n non elaborate', '$n not processed');

  String get madeBy => t('Fatta da Francesco Ferri', 'Made by Francesco Ferri');
  String get madeBySub => t('Designer e sviluppatore web', 'Web designer & developer');
  String get free => t(
    'Gratis. Nessun account. Le foto non lasciano il tuo computer.',
    'Free. No account. Your photos never leave your computer.',
  );
  String get about => t('Info', 'About');
  String get aboutBody => t(
    'Snella prende le foto, le raddrizza, le ridimensiona alle larghezze che ti servono, '
        'toglie EXIF e coordinate GPS e le salva in WebP o JPEG con nomi pronti per la SEO. '
        'Tutto in locale, sul tuo computer.',
    'Snella takes your photos, straightens them, resizes them to the widths you need, '
        'strips EXIF and GPS data and saves them as WebP or JPEG with SEO-ready names. '
        'Everything runs locally, on your computer.',
  );
  String get close => t('Chiudi', 'Close');
  String get writeMe => t('Scrivimi', 'Write to me');
}
