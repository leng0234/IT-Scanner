import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'screens/scanner_screen.dart';
import 'utils/app_constants.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load .env configuration (SNIPEIT_BASE_URL, SNIPEIT_API_TOKEN)
  await dotenv.load(fileName: '.env');

  runApp(const SnipeITApp());
}

class SnipeITApp extends StatelessWidget {
  const SnipeITApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IT Asset Scanner',
      debugShowCheckedModeBanner: false,
      theme: AppConstants.theme,
      home: const ScannerScreen(),
    );
  }
}
