import 'package:flutter/material.dart';
import 'package:timelyr/screens/home_screen.dart';
import 'package:timelyr/screens/main_screen.dart';
import 'utils/app_storage.dart';
import 'utils/artwork_cache.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await ArtworkCache.init();
  final bool firstRun = await AppStorage.isFirstRun();

  runApp(MyApp(firstRun: firstRun));
}

class MyApp extends StatelessWidget {
  final bool firstRun;

  const MyApp({super.key, required this.firstRun});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "Lyrio",

      home: firstRun ? const HomeScreen() : const MainScreen(),
    );
  }
}
