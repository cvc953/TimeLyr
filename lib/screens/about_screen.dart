import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/gestures.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text(
            'Acerca de',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          backgroundColor: const Color(0xFF0D1B2A),
        ),
        backgroundColor: const Color(0xFF0D1B2A),
        body: Center(
          child: SingleChildScrollView(
            //mainAxisAlignment: MainAxisAlignment.start,
            child: Column(
              children: [
                SizedBox(height: 20),
                Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    'TimeLyr\nTu música, tus letras.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      fontStyle: FontStyle.normal,
                    ),
                  ),
                ),
                SizedBox(height: 20),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16.0),
                  child: Text(
                    'TimeLyr es una aplicación diseñada para obtener letras de canciones almacenadas en tu dispositivo. La app lee los metadatos de tus archivos, busca letras sincronizadas (LRC) o de texto plano en LRCLib, y TTML sincronizado en lrc.red, y las guarda localmente para que puedas consultarlas sin conexión.',
                    textAlign: TextAlign.left,
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    'Características principales:\n\n'
                    '• Búsqueda automática de letras sincronizadas y de texto plano.\n'
                    '• Almacenamiento local para acceso sin conexión.\n'
                    '• Interfaz sencilla y fácil de usar.\n\n'
                    'TimeLyr es ideal para amantes de la música que desean tener sus letras favoritas siempre a mano, ya sea para cantar junto a sus canciones o simplemente para disfrutar de la poesía detrás de la música.',
                    textAlign: TextAlign.left,
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    '¡Gracias por usar TimeLyr!',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),

                Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Divider(color: Colors.white24),
                ),
                Padding(
                  padding: EdgeInsets.all(10.0),
                  child: Text(
                    'Versión de la aplicación: 1.0.1',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(10.0),
                  child: Column(
                    children: [
                      Text(
                        'Desarrollado por Cristian Villalobos Cuadrado.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      RichText(
                        text: TextSpan(
                          text: 'GitHub de la app',
                          style: TextStyle(
                            color: Colors.blueAccent,
                            decoration: TextDecoration.underline,
                            fontSize: 12,
                          ),
                          recognizer: TapGestureRecognizer()
                            ..onTap = () async {
                              final url = Uri.parse(
                                'http://github.com/cvc953/TimeLyr',
                              );
                              _launchURL(url);
                            },
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(10.0),
                  child: Column(
                    children: [
                      Text(
                        'Letras proporcionadas por la biblioteca LRCLib.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                      RichText(
                        text: TextSpan(
                          text: 'Visita LRCLib en GitHub',
                          style: TextStyle(
                            color: Colors.blueAccent,
                            decoration: TextDecoration.underline,
                            fontSize: 12,
                          ),
                          recognizer: TapGestureRecognizer()
                            ..onTap = () async {
                              final url = Uri.parse(
                                'https://github.com/tranxuanthang/lrclib',
                              );
                              _launchURL(url);
                            },
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(10.0),
                  child: Column(
                    children: [
                      Text(
                        'TTML proporcionado por lrc.red.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                      RichText(
                        text: TextSpan(
                          text: 'Visita lrc.red',
                          style: TextStyle(
                            color: Colors.blueAccent,
                            decoration: TextDecoration.underline,
                            fontSize: 12,
                          ),
                          recognizer: TapGestureRecognizer()
                            ..onTap = () async {
                              final url = Uri.parse('https://lrc.red');
                              _launchURL(url);
                            },
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(10.0),
                  child: Text(
                    '© 2025 TimeLyr. Licencia MIT.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
                SizedBox(height: 30),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _launchURL(Uri url) async {
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }
}
