# TelaPhone

**Companion app для умных часов TelaOS**

Смартфон как часть экосистемы: AI-ассистент, BLE мост для интернета, трансляция экрана и эмулятор.

---

## Возможности

### 🧠 AI-ассистент

Создание приложений голосом:

```
Вы: "Создай счётчик с кнопками плюс и минус"
AI: ✨ Генерирует код
Вы: "Сделай кнопки зелёной и красной"
AI: ✨ Обновляет дизайн
→ Эмулятор показывает результат
→ Отправка на часы одним кликом
```

### 🌐 BLE мост

Интернет для часов через телефон:

```lua
-- На часах
fetch({
  url = "https://api.weather.com/data"
}, function(response)
  state.temp = response.data.temp
end)
```

TelaPhone принимает запрос по Bluetooth, делает HTTP, возвращает ответ.

### 📺 Трансляция экрана

```
┌─────────────────────┐
│   ┌───────────┐     │
│   │  ⌚ 14:32 │     │  ← Экран часов
│   │ [ START ] │     │    в реальном времени
│   │ [ STOP  ] │     │
│   └───────────┘     │
│                     │
│  👆 Touch управление│
│  📸 Скриншот        │
└─────────────────────┘
```

- RGB16, RGB8, Gray, B/W режимы
- Тапы и свайпы с телефона
- Режим tiny (уменьшение 2x)

### ⚡ Эмулятор

- Тестирование до загрузки на часы
- Lua runtime в браузере
- Мгновенное обновление кода

---

## Пример: Погодное приложение

**Голосом:** *"Создай погоду с большой температурой и кнопкой обновить"*

**AI генерирует:**

```xml
<app>
  <system><bluetooth/></system>
  
  <ui default="/main">
    <page id="main">
      <label align="center" y="30%" font="72">{temp}°C</label>
      <label align="center" y="50%">{city}</label>
      <button align="center" y="80%" w="60%" onclick="update">
        Обновить
      </button>
    </page>
  </ui>
  
  <state>
    <string name="temp" default="--"/>
    <string name="city" default="..."/>
  </state>
  
  <script language="lua">
    function update()
      fetch({
        url = "https://api.openweathermap.org/..."
      }, function(r)
        local data = json.parse(r.body)
        state.temp = math.floor(data.main.temp - 273)
        state.city = data.name
      end)
    end
    
    update()
  </script>
</app>
```

---

## Протокол

Console Protocol v2.7 (JSON-RPC over BLE):

```json
// Синхронизация
[1, "sys", "sync", ["2.7", "2026-02-20T12:00:00Z", "+03:00"]]

// HTTP прокси
[2, "http", "fetch", [123, "GET", "https://...", {}, ""]]

// Touch
[3, "ui", "tap", ["120", "160"]]
[4, "ui", "swipe", ["left"]]

// Push приложения
[5, "app", "push", ["timer", "app.html", 9924]]

// Скриншот
[6, "sys", "screen", ["rgb16", "0"]]
```

---

## Сборка

```bash
flutter pub get
flutter build apk --release
```

## Структура

```
lib/
├── main.dart
├── screens/
│   ├── home_screen.dart       # Главный экран  
│   ├── apps_screen.dart       # Редактор + AI чат
│   ├── screenshot_screen.dart # Трансляция
│   ├── emulator_screen.dart   # Эмулятор
│   ├── commands_screen.dart   # Консоль
│   └── settings_screen.dart   # Настройки
└── services/
    ├── ble_service.dart       # BLE коммуникация
    └── local_server.dart      # HTTP для эмулятора
```

## Требования

- Flutter 3.24+
- Android 6.0+ / iOS 12+
- Bluetooth LE 4.0+
