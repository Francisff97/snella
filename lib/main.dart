import 'package:material_ui/material_ui.dart';

import 'src/brand.dart';
import 'src/home_page.dart';

void main() {
  runApp(const SnellaApp());
}

class SnellaApp extends StatelessWidget {
  const SnellaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(title: 'Snella', debugShowCheckedModeBanner: false, theme: buildTheme(), home: const HomePage());
  }
}
