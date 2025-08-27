import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

/// ------------------------------------------------------------
///  Empacaduras Price Calculator (Android + Web, offline)
///  - Datos persistidos con SharedPreferences (LocalStorage en Web)
///  - Configuración protegida con usuario/contraseña (admin)
///  - Ganancia y Merma definidas por **espesor** (solo visible en Configurar material)
///  - Mínimo de venta por espesor y redondeo comercial global
///  - Cálculo: precio_cm2 = costo_lámina / área_lámina_cm2
///             area_base = ancho_cm * largo_cm
///             area_con_merma = area_base * (1 + merma%/100)
///             costo_material = area_con_merma * precio_cm2
///             subtotal = costo_material + mano_de_obra
///             total_raw = subtotal * (1 + ganancia_espesor%/100)
///             total = redondear(max(total_raw, minimo_espesor))
/// ------------------------------------------------------------

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Calculadora de Empacaduras',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const PriceCalculatorPage(),
    );
  }
}

class ThicknessOption {
  String label; // ej. "1.2 mm" o "1/32"
  double costPerSheetUSD; // costo de la lámina para este espesor
  double profitPct; // % de ganancia aplicado al subtotal para este espesor
  double wastePct; // % de merma aplicada al área de la pieza
  double minPriceUSD; // precio mínimo por pieza para este espesor

  ThicknessOption({
    required this.label,
    required this.costPerSheetUSD,
    this.profitPct = 0.0,
    this.wastePct = 0.0,
    this.minPriceUSD = 0.0,
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        'costPerSheetUSD': costPerSheetUSD,
        'profitPct': profitPct,
        'wastePct': wastePct,
        'minPriceUSD': minPriceUSD,
      };

  factory ThicknessOption.fromJson(Map<String, dynamic> j) => ThicknessOption(
        label: j['label'] as String,
        costPerSheetUSD: (j['costPerSheetUSD'] as num).toDouble(),
        profitPct: j['profitPct'] == null ? 0.0 : (j['profitPct'] as num).toDouble(),
        wastePct: j['wastePct'] == null ? 0.0 : (j['wastePct'] as num).toDouble(),
        minPriceUSD: j['minPriceUSD'] == null ? 0.0 : (j['minPriceUSD'] as num).toDouble(),
      );
}

class MaterialConfig {
  String id; // "camara", "amianto", "velumoide", "corcho", etc.
  String name; // nombre visible
  double sheetWidthCm; // ancho de lámina en cm
  double sheetHeightCm; // alto de lámina en cm
  List<ThicknessOption> options;

  MaterialConfig({
    required this.id,
    required this.name,
    required this.sheetWidthCm,
    required this.sheetHeightCm,
    required this.options,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sheetWidthCm': sheetWidthCm,
        'sheetHeightCm': sheetHeightCm,
        'options': options.map((e) => e.toJson()).toList(),
      };

  factory MaterialConfig.fromJson(Map<String, dynamic> j) => MaterialConfig(
        id: j['id'] as String,
        name: j['name'] as String,
        sheetWidthCm: (j['sheetWidthCm'] as num).toDouble(),
        sheetHeightCm: (j['sheetHeightCm'] as num).toDouble(),
        options: (j['options'] as List).map((e) => ThicknessOption.fromJson(e)).toList(),
      );
}

class PriceCalculatorPage extends StatefulWidget {
  const PriceCalculatorPage({super.key});

  @override
  State<PriceCalculatorPage> createState() => _PriceCalculatorPageState();
}

class _PriceCalculatorPageState extends State<PriceCalculatorPage> {
  final _formKey = GlobalKey<FormState>();

  final _widthCtrl = TextEditingController();
  final _heightCtrl = TextEditingController();
  final _hoursCtrl = TextEditingController(text: '0');

  List<MaterialConfig> _materials = [];
  String? _selectedMaterialId;
  int _selectedThicknessIndex = 0;
  double _hourlyRate = 6.0; // USD/h

  // Redondeo comercial global (0 = desactivado)
  double _roundingStepUSD = 0.0;

  // Auth (simple, offline):
  bool _isAdminAuthed = false; // válido solo durante la sesión
  String _adminUser = 'admin';
  String _adminPassEnc = base64.encode(utf8.encode('1234')); // default "1234" (base64)

  // Resultados
  double? _areaBaseCm2;
  double? _areaWithWasteCm2;
  double? _pricePerCm2;
  double? _materialCost;
  double? _laborCost;
  double? _total;
  bool _appliedMin = false;
  bool _appliedRounding = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _widthCtrl.dispose();
    _heightCtrl.dispose();
    _hoursCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();

    // Credenciales guardadas (si existen)
    _adminUser = prefs.getString('adminUser') ?? 'admin';
    _adminPassEnc = prefs.getString('adminPassEnc') ?? base64.encode(utf8.encode('1234'));

    final raw = prefs.getString('materialsData');
    final savedRate = prefs.getDouble('hourlyRate');
    final savedStep = prefs.getDouble('roundingStepUSD');

    if (savedRate != null) _hourlyRate = savedRate;
    if (savedStep != null) _roundingStepUSD = savedStep;

    if (raw == null) {
      _materials = _defaultMaterials();
      await prefs.setString('materialsData', jsonEncode(_materials.map((m) => m.toJson()).toList()));
    } else {
      try {
        final list = jsonDecode(raw) as List;
        _materials = list.map((e) => MaterialConfig.fromJson(e)).toList();
      } catch (_) {
        _materials = _defaultMaterials();
      }
    }

    _selectedMaterialId = _materials.first.id;
    _selectedThicknessIndex = 0;

    setState(() {});
  }

  List<MaterialConfig> _defaultMaterials() {
    return [
      MaterialConfig(
        id: 'camara',
        name: 'Cámara',
        // 0.50 m x 1.20 m = 50 cm x 120 cm = 6000 cm²
        sheetWidthCm: 50,
        sheetHeightCm: 120,
        options: [
          ThicknessOption(label: '1.2 mm', costPerSheetUSD: 15.0),
          ThicknessOption(label: '1.6 mm', costPerSheetUSD: 17.5),
          ThicknessOption(label: '2.0 mm', costPerSheetUSD: 19.0),
          ThicknessOption(label: '2.5 mm', costPerSheetUSD: 20.0),
          ThicknessOption(label: '3.0 mm', costPerSheetUSD: 38.7),
          ThicknessOption(label: '3.5 mm', costPerSheetUSD: 44.0),
          ThicknessOption(label: '4.0 mm', costPerSheetUSD: 68.0),
          ThicknessOption(label: '4.5 mm', costPerSheetUSD: 92.0),
        ],
      ),
      MaterialConfig(
        id: 'amianto',
        name: 'Amianto',
        sheetWidthCm: 150,
        sheetHeightCm: 150,
        options: [
          ThicknessOption(label: '1/64', costPerSheetUSD: 0.0),
          ThicknessOption(label: '1/32', costPerSheetUSD: 0.0),
          ThicknessOption(label: '1/16', costPerSheetUSD: 0.0),
          ThicknessOption(label: '1/8', costPerSheetUSD: 0.0),
          ThicknessOption(label: '3/32', costPerSheetUSD: 0.0),
          ThicknessOption(label: '1/4', costPerSheetUSD: 0.0),
        ],
      ),
      MaterialConfig(
        id: 'velumoide',
        name: 'Velumoide',
        sheetWidthCm: 100,
        sheetHeightCm: 100,
        options: [
          ThicknessOption(label: '1/64', costPerSheetUSD: 0.0),
          ThicknessOption(label: '1/32', costPerSheetUSD: 0.0),
          ThicknessOption(label: '1/16', costPerSheetUSD: 0.0),
        ],
      ),
      MaterialConfig(
        id: 'corcho',
        name: 'Corcho',
        sheetWidthCm: 100,
        sheetHeightCm: 100,
        options: [
          ThicknessOption(label: '2 mm', costPerSheetUSD: 0.0),
          ThicknessOption(label: '4 mm', costPerSheetUSD: 0.0),
        ],
      ),
      MaterialConfig(
        id: 'neopreno_cl',
        name: 'Neopreno con lona (próx.)',
        sheetWidthCm: 0,
        sheetHeightCm: 0,
        options: [],
      ),
      MaterialConfig(
        id: 'neopreno_sl',
        name: 'Neopreno sin lona (próx.)',
        sheetWidthCm: 0,
        sheetHeightCm: 0,
        options: [],
      ),
    ];
  }

  MaterialConfig get _currentMaterial => _materials.firstWhere((m) => m.id == _selectedMaterialId);

  ThicknessOption? get _currentThicknessOption {
    final opts = _currentMaterial.options;
    if (opts.isEmpty) return null;
    if (_selectedThicknessIndex < 0 || _selectedThicknessIndex >= opts.length) return null;
    return opts[_selectedThicknessIndex];
  }

  // Validación de configuración lista
  bool get _isConfigReady {
    final m = _currentMaterial;
    final th = _currentThicknessOption;
    return m.sheetWidthCm > 0 && m.sheetHeightCm > 0 && th != null && th.costPerSheetUSD > 0;
  }

  double _parseNum(TextEditingController c) {
    final s = c.text.trim().replaceAll(',', '.');
    if (s.isEmpty) return 0.0;
    return double.tryParse(s) ?? 0.0;
  }

  double _parseFromDialog(String s) {
    return double.tryParse(s.trim().replaceAll(',', '.')) ?? 0.0;
  }

  void _calculate() {
    if (!_formKey.currentState!.validate()) return;

    final mat = _currentMaterial;
    final th = _currentThicknessOption;

    if (mat.sheetWidthCm <= 0 || mat.sheetHeightCm <= 0) {
      _showSnack('Configura el tamaño de la lámina para ${mat.name}.');
      return;
    }
    if (th == null || th.costPerSheetUSD <= 0) {
      _showSnack('Configura el costo de lámina para el espesor seleccionado.');
      return;
    }

    final width = _parseNum(_widthCtrl);
    final height = _parseNum(_heightCtrl);
    final hours = _parseNum(_hoursCtrl);

    if (width <= 0 || height <= 0) {
      _showSnack('Ancho y Largo deben ser mayores que 0.');
      return;
    }

    final areaBaseCm2 = width * height; // área de la pieza
    final sheetAreaCm2 = mat.sheetWidthCm * mat.sheetHeightCm;
    final pricePerCm2 = th.costPerSheetUSD / sheetAreaCm2;

    // Merma por espesor
    final areaWithWasteCm2 = areaBaseCm2 * (1 + (th.wastePct / 100.0));

    final materialCost = areaWithWasteCm2 * pricePerCm2;
    final laborCost = hours * _hourlyRate;

    final subtotal = materialCost + laborCost;
    final totalRaw = subtotal * (1 + (th.profitPct / 100.0));

    // Aplicar mínimo y redondeo
    double total = totalRaw;
    _appliedMin = false;
    _appliedRounding = false;

    if (th.minPriceUSD > 0 && total < th.minPriceUSD) {
      total = th.minPriceUSD;
      _appliedMin = true;
    }
    if (_roundingStepUSD > 0) {
      total = _roundToStep(total, _roundingStepUSD);
      _appliedRounding = true;
    }

    setState(() {
      _areaBaseCm2 = areaBaseCm2;
      _areaWithWasteCm2 = areaWithWasteCm2;
      _pricePerCm2 = pricePerCm2;
      _materialCost = materialCost;
      _laborCost = laborCost;
      _total = total;
    });
  }

  double _roundToStep(double value, double step) {
    if (step <= 0) return value;
    return (value / step).round() * step; // redondeo al múltiplo más cercano
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool> _promptAdminLogin() async {
    final uCtrl = TextEditingController();
    final pCtrl = TextEditingController();
    bool ok = false;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Acceso restringido'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: uCtrl,
              decoration: const InputDecoration(labelText: 'Usuario'),
            ),
            TextField(
              controller: pCtrl,
              decoration: const InputDecoration(labelText: 'Contraseña'),
              obscureText: true,
            ),
            const SizedBox(height: 8),
            const Text('Usuario por defecto "admin" y contraseña "1234" (puedes cambiarlos).', style: TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () {
              final userOk = uCtrl.text.trim() == _adminUser;
              final passOk = base64.encode(utf8.encode(pCtrl.text.trim())) == _adminPassEnc;
              if (!userOk || !passOk) {
                _showSnack('Usuario o contraseña incorrectos');
                return;
              }
              ok = true;
              Navigator.pop(ctx);
            },
            child: const Text('Entrar'),
          ),
        ],
      ),
    );
    if (ok) setState(() => _isAdminAuthed = true);
    return ok;
  }

  Future<void> _openMaterialEditor() async {
    final mat = _currentMaterial;
    final widthCtrl = TextEditingController(text: _fmt(mat.sheetWidthCm));
    final heightCtrl = TextEditingController(text: _fmt(mat.sheetHeightCm));

    // Controllers por espesor
    final costCtrls = [for (final opt in mat.options) TextEditingController(text: _fmt(opt.costPerSheetUSD))];
    final profitCtrls = [for (final opt in mat.options) TextEditingController(text: _fmt(opt.profitPct))];
    final wasteCtrls = [for (final opt in mat.options) TextEditingController(text: _fmt(opt.wastePct))];
    final minCtrls = [for (final opt in mat.options) TextEditingController(text: _fmt(opt.minPriceUSD))];

    // Campos masivos (aplicar a todos)
    final bulkProfitCtrl = TextEditingController();
    final bulkWasteCtrl  = TextEditingController();
    final bulkMinCtrl    = TextEditingController();

    // Filtro simple: solo números, punto/coma, sin signo
    final numberInput = <TextInputFormatter>[
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
      FilteringTextInputFormatter.deny(RegExp(r'-')),
    ];

    await showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Encabezado
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Editar ${mat.name}', style: Theme.of(context).textTheme.titleLarge),
                      IconButton(
                        tooltip: 'Cerrar',
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Tamaño de lámina
                  const Text('Tamaño de lámina (cm)', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: widthCtrl,
                        decoration: const InputDecoration(labelText: 'Ancho', suffixText: ' cm', border: OutlineInputBorder()),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: numberInput,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: heightCtrl,
                        decoration: const InputDecoration(labelText: 'Alto', suffixText: ' cm', border: OutlineInputBorder()),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: numberInput,
                      ),
                    ),
                  ]),

                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 6),

                  // Barra de acciones masivas
                  Row(
                    children: [
                      const Icon(Icons.tune, size: 20),
                      const SizedBox(width: 8),
                      const Text('Aplicar a todos los espesores'),
                      const Spacer(),
                      SizedBox(
                        width: 140,
                        child: TextField(
                          controller: bulkProfitCtrl,
                          textAlign: TextAlign.right,
                          decoration: const InputDecoration(labelText: 'Ganancia %', border: OutlineInputBorder(), suffixText: ' %'),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: numberInput,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 140,
                        child: TextField(
                          controller: bulkWasteCtrl,
                          textAlign: TextAlign.right,
                          decoration: const InputDecoration(labelText: 'Merma %', border: OutlineInputBorder(), suffixText: ' %'),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: numberInput,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 150,
                        child: TextField(
                          controller: bulkMinCtrl,
                          textAlign: TextAlign.right,
                          decoration: const InputDecoration(labelText: 'Mínimo USD', border: OutlineInputBorder(), prefixText: '\$ '),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: numberInput,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: () {
                          final p = _parseFromDialog(bulkProfitCtrl.text);
                          final w = _parseFromDialog(bulkWasteCtrl.text);
                          final m = _parseFromDialog(bulkMinCtrl.text);
                          setState(() {
                            for (int i = 0; i < mat.options.length; i++) {
                              if (bulkProfitCtrl.text.trim().isNotEmpty) profitCtrls[i].text = _fmt(p);
                              if (bulkWasteCtrl.text.trim().isNotEmpty)  wasteCtrls[i].text  = _fmt(w);
                              if (bulkMinCtrl.text.trim().isNotEmpty)    minCtrls[i].text    = _fmt(m);
                            }
                          });
                        },
                        icon: const Icon(Icons.content_paste_go),
                        label: const Text('Aplicar'),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),
                  const Text('Parámetros por espesor', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),

                  // Tabla de espesores
                  SizedBox(
                    height: 360,
                    child: Scrollbar(
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 820),
                          child: DataTable(
                            headingRowHeight: 44,
                            dataRowMinHeight: 56,
                            columns: const [
                              DataColumn(label: Text('Espesor')),
                              DataColumn(label: Text('Costo (USD)')),
                              DataColumn(label: Text('Ganancia %')),
                              DataColumn(label: Text('Merma %')),
                              DataColumn(label: Text('Mínimo (USD)')),
                            ],
                            rows: List.generate(mat.options.length, (i) {
                              return DataRow(cells: [
                                DataCell(Text(mat.options[i].label)),
                                DataCell(SizedBox(
                                  width: 130,
                                  child: TextField(
                                    controller: costCtrls[i],
                                    textAlign: TextAlign.right,
                                    decoration: const InputDecoration(prefixText: '\$ ', border: OutlineInputBorder()),
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    inputFormatters: numberInput,
                                  ),
                                )),
                                DataCell(SizedBox(
                                  width: 130,
                                  child: TextField(
                                    controller: profitCtrls[i],
                                    textAlign: TextAlign.right,
                                    decoration: const InputDecoration(suffixText: ' %', border: OutlineInputBorder()),
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    inputFormatters: numberInput,
                                  ),
                                )),
                                DataCell(SizedBox(
                                  width: 130,
                                  child: TextField(
                                    controller: wasteCtrls[i],
                                    textAlign: TextAlign.right,
                                    decoration: const InputDecoration(suffixText: ' %', border: OutlineInputBorder()),
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    inputFormatters: numberInput,
                                  ),
                                )),
                                DataCell(SizedBox(
                                  width: 140,
                                  child: TextField(
                                    controller: minCtrls[i],
                                    textAlign: TextAlign.right,
                                    decoration: const InputDecoration(prefixText: '\$ ', border: OutlineInputBorder()),
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    inputFormatters: numberInput,
                                  ),
                                )),
                              ]);
                            }),
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () async {
                          // Validaciones: no negativos ni NaN
                          final w = _parseFromDialog(widthCtrl.text);
                          final h = _parseFromDialog(heightCtrl.text);
                          if (w <= 0 || h <= 0) {
                            _showSnack('Ancho/Alto de lámina deben ser > 0');
                            return;
                          }
                          for (int i = 0; i < mat.options.length; i++) {
                            final c = _parseFromDialog(costCtrls[i].text);
                            final p = _parseFromDialog(profitCtrls[i].text);
                            final wa = _parseFromDialog(wasteCtrls[i].text);
                            final mi = _parseFromDialog(minCtrls[i].text);
                            if (c < 0 || p < 0 || wa < 0 || mi < 0) {
                              _showSnack('Valores negativos en la fila ${i + 1}. Corrige antes de guardar.');
                              return;
                            }
                          }

                          // Guardado
                          mat.sheetWidthCm = w;
                          mat.sheetHeightCm = h;
                          for (int i = 0; i < mat.options.length; i++) {
                            mat.options[i].costPerSheetUSD = _parseFromDialog(costCtrls[i].text);
                            mat.options[i].profitPct      = _parseFromDialog(profitCtrls[i].text);
                            mat.options[i].wastePct       = _parseFromDialog(wasteCtrls[i].text);
                            mat.options[i].minPriceUSD    = _parseFromDialog(minCtrls[i].text);
                          }
                          await _saveMaterials();
                          if (mounted) Navigator.pop(ctx);
                          setState(() {});
                        },
                        child: const Text('Guardar'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancelar'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () async {
                          final w = _parseFromDialog(widthCtrl.text);
                          final h = _parseFromDialog(heightCtrl.text);
                          if (w <= 0 || h <= 0) {
                            _showSnack('Ancho/Alto de lámina deben ser > 0');
                            return;
                          }
                          mat.sheetWidthCm = w;
                          mat.sheetHeightCm = h;
                          for (int i = 0; i < mat.options.length; i++) {
                            mat.options[i].costPerSheetUSD = _parseFromDialog(costCtrls[i].text);
                            mat.options[i].profitPct = _parseFromDialog(profitCtrls[i].text);
                            mat.options[i].wastePct = _parseFromDialog(wasteCtrls[i].text);
                            mat.options[i].minPriceUSD = _parseFromDialog(minCtrls[i].text);
                          }
                          await _saveMaterials();
                          if (mounted) Navigator.pop(ctx);
                          setState(() {});
                        },
                        child: const Text('Guardar'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
