import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const BrumaireApp());
}

class BrumaireApp extends StatelessWidget {
  const BrumaireApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Brumaire',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      // Textos de Material (calendario, botones) en español.
      locale: const Locale('es'),
      supportedLocales: const [Locale('es')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: const HomeScreen(),
    );
  }
}
