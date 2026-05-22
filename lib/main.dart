import 'package:flutter/material.dart';
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
      home: const HomeScreen(),
    );
  }
}
