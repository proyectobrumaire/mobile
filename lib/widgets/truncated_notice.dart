import 'package:flutter/material.dart';

/// Aviso de respuesta recortada por la nube (máx. 500 elementos).
class TruncatedNotice extends StatelessWidget {
  final String what;
  final bool femenino;
  const TruncatedNotice({super.key, required this.what, this.femenino = true});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: Colors.orange.shade800),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Hay más $what de ${femenino ? 'las' : 'los'} que se pueden mostrar '
              '(máx. 500). Se muestran ${femenino ? 'las' : 'los'} más recientes; '
              'elige un rango más corto o filtra para ver el resto.',
              style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
            ),
          ),
        ],
      ),
    );
  }
}
