# Standalone Deployment

Runtime для Evolution OS приложений — можно развернуть на любом веб-сервере или использовать локально.

## Быстрый старт (без сервера!)

```bash
cd assets/server
python build_standalone.py
```

Создаст `standalone.html` — один файл со всем внутри:
- Runtime + эмулятор
- Кнопки Run и Validate
- wasmoon.js (inline)
- glue.wasm (base64)

**Просто открой standalone.html в браузере!**

## Для nginx

Если нужен полноценный сервер:

```
server/
├── runtime.html    # → index.html
├── wasmoon.js
├── glue.wasm
└── validate.html   # из standalone/
```

```nginx
server {
    listen 80;
    server_name evo.example.com;
    root /var/www/evo-runtime;
    
    location / {
        try_files $uri $uri/ /index.html;
    }
    
    add_header Access-Control-Allow-Origin *;
}
```

## JavaScript API

```javascript
// В консоли браузера:

// Загрузить и запустить приложение
loadApp('<app os="1.0" title="test">...</app>');

// Валидировать код
var result = validateCode('<app>...</app>');
console.log(result);
// {valid: true/false, errors: [...], warnings: [...], stats: {...}}

// Консоль
getConsole()     // получить логи
clearConsole()   // очистить
```

## Интеграция с Flutter

```dart
// Валидация через WebView
final result = await webViewController.runJavaScriptReturningResult(
  'JSON.stringify(validateCode(`$code`))'
);

// Получить консоль
final logs = await webViewController.runJavaScriptReturningResult(
  'JSON.stringify(getConsole())'
);
```
