/// Валидатор и линтер для TelaOS приложений
/// Проверяет XML структуру, Lua синтаксис, соответствие onclick/state

class ValidationResult {
  final List<ValidationError> errors;
  final List<ValidationWarning> warnings;
  
  ValidationResult({
    this.errors = const [],
    this.warnings = const [],
  });
  
  bool get isValid => errors.isEmpty;
  bool get hasWarnings => warnings.isNotEmpty;
  
  String get summary {
    if (errors.isEmpty && warnings.isEmpty) {
      return 'Код валиден ✓';
    }
    final parts = <String>[];
    if (errors.isNotEmpty) {
      parts.add('${errors.length} ошибок');
    }
    if (warnings.isNotEmpty) {
      parts.add('${warnings.length} предупреждений');
    }
    return parts.join(', ');
  }
  
  String get report {
    final buf = StringBuffer();
    if (errors.isNotEmpty) {
      buf.writeln('ОШИБКИ:');
      for (final e in errors) {
        buf.writeln('• ${e.message}');
        if (e.context != null) buf.writeln('  Контекст: ${e.context}');
      }
    }
    if (warnings.isNotEmpty) {
      if (buf.isNotEmpty) buf.writeln();
      buf.writeln('ПРЕДУПРЕЖДЕНИЯ:');
      for (final w in warnings) {
        buf.writeln('• ${w.message}');
      }
    }
    return buf.toString();
  }
}

class ValidationError {
  final String message;
  final String? context;
  final int? line;
  
  ValidationError(this.message, {this.context, this.line});
}

class ValidationWarning {
  final String message;
  final int? line;
  
  ValidationWarning(this.message, {this.line});
}

class AppValidator {
  /// Полная валидация приложения
  static ValidationResult validate(String code) {
    final errors = <ValidationError>[];
    final warnings = <ValidationWarning>[];
    
    // 1. XML валидация
    final xmlResult = _validateXml(code);
    errors.addAll(xmlResult.errors);
    warnings.addAll(xmlResult.warnings);
    
    if (errors.isNotEmpty) {
      // Если XML невалиден, дальше не проверяем
      return ValidationResult(errors: errors, warnings: warnings);
    }
    
    // 2. Извлекаем компоненты
    final luaCode = _extractLuaCode(code);
    final onclickFunctions = _extractOnclickFunctions(code);
    final onchangeFunctions = _extractOnchangeFunctions(code);
    final stateVariables = _extractStateVariables(code);
    final bindVariables = _extractBindVariables(code);
    
    // 3. Lua синтаксис
    if (luaCode.isNotEmpty) {
      final luaResult = _validateLuaSyntax(luaCode);
      errors.addAll(luaResult.errors);
      warnings.addAll(luaResult.warnings);
    }
    
    // 4. Извлекаем определённые функции из Lua
    final definedFunctions = _extractDefinedFunctions(luaCode);
    
    // 5. Проверяем onclick -> функции существуют
    for (final fn in onclickFunctions) {
      if (!definedFunctions.contains(fn)) {
        errors.add(ValidationError(
          'Функция "$fn" используется в onclick, но не определена в script',
          context: 'onclick="$fn"',
        ));
      }
    }
    
    // 6. Проверяем onchange -> функции существуют
    for (final fn in onchangeFunctions) {
      if (!definedFunctions.contains(fn)) {
        errors.add(ValidationError(
          'Функция "$fn" используется в onchange, но не определена в script',
          context: 'onchange="$fn"',
        ));
      }
    }
    
    // 7. Проверяем bind -> state существует
    for (final v in bindVariables) {
      if (!stateVariables.contains(v)) {
        errors.add(ValidationError(
          'Переменная "$v" используется в bind, но не объявлена в state',
          context: 'bind="$v"',
        ));
      }
    }
    
    // 8. Проверяем {var} биндинги в тексте
    final textBindings = _extractTextBindings(code);
    for (final v in textBindings) {
      if (!stateVariables.contains(v)) {
        warnings.add(ValidationWarning(
          'Переменная "$v" используется в шаблоне {$v}, но не объявлена в state',
        ));
      }
    }
    
    // 9. Проверяем неиспользуемые функции
    final usedFunctions = {...onclickFunctions, ...onchangeFunctions};
    for (final fn in definedFunctions) {
      if (!usedFunctions.contains(fn) && !_isSystemFunction(fn)) {
        warnings.add(ValidationWarning(
          'Функция "$fn" определена, но не используется',
        ));
      }
    }
    
    return ValidationResult(errors: errors, warnings: warnings);
  }
  
  /// Быстрая проверка только критических ошибок
  static ValidationResult quickValidate(String code) {
    final errors = <ValidationError>[];
    
    // XML валидация
    final xmlResult = _validateXml(code);
    errors.addAll(xmlResult.errors);
    
    if (errors.isNotEmpty) return ValidationResult(errors: errors);
    
    // Lua базовый синтаксис
    final luaCode = _extractLuaCode(code);
    if (luaCode.isNotEmpty) {
      final luaResult = _validateLuaSyntax(luaCode);
      errors.addAll(luaResult.errors);
    }
    
    // onclick -> функции
    final onclickFunctions = _extractOnclickFunctions(code);
    final definedFunctions = _extractDefinedFunctions(luaCode);
    
    for (final fn in onclickFunctions) {
      if (!definedFunctions.contains(fn)) {
        errors.add(ValidationError(
          'Функция "$fn" не определена',
          context: 'onclick="$fn"',
        ));
      }
    }
    
    return ValidationResult(errors: errors);
  }
  
  // === XML ===
  
  static ValidationResult _validateXml(String code) {
    final errors = <ValidationError>[];
    final warnings = <ValidationWarning>[];
    
    // Проверяем корневой тег
    if (!code.contains('<app')) {
      errors.add(ValidationError('Отсутствует корневой тег <app>'));
      return ValidationResult(errors: errors);
    }
    
    // Проверяем закрытие тегов
    final openTags = <String>[];
    final tagRegex = RegExp(r'<(/?)(\w+)(?:\s[^>]*)?(\/?)>');
    
    for (final match in tagRegex.allMatches(code)) {
      final isClosing = match.group(1) == '/';
      final tagName = match.group(2)!;
      final isSelfClosing = match.group(3) == '/';
      
      // Игнорируем самозакрывающиеся
      if (isSelfClosing) continue;
      
      // Игнорируем теги внутри script
      final beforeMatch = code.substring(0, match.start);
      if (beforeMatch.contains('<script') && !beforeMatch.contains('</script>')) {
        continue;
      }
      
      if (isClosing) {
        if (openTags.isEmpty) {
          errors.add(ValidationError('Лишний закрывающий тег </$tagName>'));
        } else if (openTags.last != tagName) {
          errors.add(ValidationError(
            'Неправильный порядок закрытия тегов: ожидался </${openTags.last}>, получен </$tagName>',
          ));
        } else {
          openTags.removeLast();
        }
      } else {
        // Самозакрывающиеся теги
        const selfClosing = {'bluetooth', 'network', 'timer', 'string', 'int', 'bool', 'float', 'image', 'slider', 'switch', 'input'};
        if (!selfClosing.contains(tagName)) {
          openTags.add(tagName);
        }
      }
    }
    
    for (final tag in openTags) {
      errors.add(ValidationError('Незакрытый тег <$tag>'));
    }
    
    return ValidationResult(errors: errors, warnings: warnings);
  }
  
  // === Lua ===
  
  static String _extractLuaCode(String code) {
    final match = RegExp(r'<script[^>]*>([\s\S]*?)</script>').firstMatch(code);
    return match?.group(1)?.trim() ?? '';
  }
  
  static ValidationResult _validateLuaSyntax(String lua) {
    final errors = <ValidationError>[];
    final warnings = <ValidationWarning>[];
    
    // Считаем блоки
    int blocks = 0;
    final lines = lua.split('\n');
    
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      final lineNum = i + 1;
      
      // Пропускаем комментарии
      if (line.startsWith('--')) continue;
      
      // Убираем строковые литералы для анализа
      final noStrings = line.replaceAll(RegExp(r'"[^"]*"'), '""').replaceAll(RegExp(r"'[^']*'"), "''");
      
      // Открывающие блоки
      if (RegExp(r'\bfunction\b').hasMatch(noStrings)) blocks++;
      if (RegExp(r'\bif\b').hasMatch(noStrings) && !RegExp(r'\belseif\b').hasMatch(noStrings)) blocks++;
      if (RegExp(r'\bfor\b').hasMatch(noStrings)) blocks++;
      if (RegExp(r'\bwhile\b').hasMatch(noStrings)) blocks++;
      if (RegExp(r'\brepeat\b').hasMatch(noStrings)) blocks++;
      
      // Закрывающие блоки
      if (RegExp(r'\bend\b').hasMatch(noStrings)) blocks--;
      if (RegExp(r'\buntil\b').hasMatch(noStrings)) blocks--;
      
      // Проверяем негативный баланс
      if (blocks < 0) {
        errors.add(ValidationError('Лишний "end" или "until"', line: lineNum));
        blocks = 0;
      }
      
      // Проверяем частые ошибки
      if (line.contains('then') && !line.contains('if') && !line.contains('elseif')) {
        warnings.add(ValidationWarning('Подозрительный "then" без "if"', line: lineNum));
      }
      
      // Проверяем == vs =
      if (RegExp(r'\bif\b.*[^=!<>]=[^=]').hasMatch(noStrings)) {
        warnings.add(ValidationWarning('Возможно имелось в виду "==" вместо "=" в условии', line: lineNum));
      }
    }
    
    if (blocks > 0) {
      errors.add(ValidationError('Не хватает $blocks "end" для закрытия блоков'));
    }
    
    return ValidationResult(errors: errors, warnings: warnings);
  }
  
  static Set<String> _extractDefinedFunctions(String lua) {
    final functions = <String>{};
    final regex = RegExp(r'function\s+(\w+)\s*\(');
    
    for (final match in regex.allMatches(lua)) {
      functions.add(match.group(1)!);
    }
    
    return functions;
  }
  
  static bool _isSystemFunction(String name) {
    const system = {'init', 'setup', 'update', 'tick', 'onInit', 'onLoad'};
    return system.contains(name);
  }
  
  // === Атрибуты ===
  
  static Set<String> _extractOnclickFunctions(String code) {
    final functions = <String>{};
    final regex = RegExp(r'onclick="(\w+)"');
    
    for (final match in regex.allMatches(code)) {
      functions.add(match.group(1)!);
    }
    
    return functions;
  }
  
  static Set<String> _extractOnchangeFunctions(String code) {
    final functions = <String>{};
    final regex = RegExp(r'on(?:change|enter|blur|hold)="(\w+)"');
    
    for (final match in regex.allMatches(code)) {
      functions.add(match.group(1)!);
    }
    
    return functions;
  }
  
  static Set<String> _extractStateVariables(String code) {
    final variables = <String>{};
    final regex = RegExp(r'<(?:string|int|bool|float)\s+name="(\w+)"');
    
    for (final match in regex.allMatches(code)) {
      variables.add(match.group(1)!);
    }
    
    return variables;
  }
  
  static Set<String> _extractBindVariables(String code) {
    final variables = <String>{};
    final regex = RegExp(r'bind="(\w+)"');
    
    for (final match in regex.allMatches(code)) {
      variables.add(match.group(1)!);
    }
    
    return variables;
  }
  
  static Set<String> _extractTextBindings(String code) {
    final variables = <String>{};
    
    // Извлекаем текст между тегами (не атрибуты)
    final textRegex = RegExp(r'>([^<]+)<');
    for (final match in textRegex.allMatches(code)) {
      final text = match.group(1)!;
      final varRegex = RegExp(r'\{(\w+)\}');
      for (final varMatch in varRegex.allMatches(text)) {
        variables.add(varMatch.group(1)!);
      }
    }
    
    // Также проверяем биндинги в атрибутах типа bgcolor="{color}"
    final attrRegex = RegExp(r'(?:bgcolor|color|visible|class)="\{(\w+)\}"');
    for (final match in attrRegex.allMatches(code)) {
      variables.add(match.group(1)!);
    }
    
    return variables;
  }
}
