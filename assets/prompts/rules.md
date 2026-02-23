# UI HTML Specification

Декларативный язык разметки для приложений на ESP32 с LVGL.

## Структура app.html

```xml
<app>
  <system>
    <bluetooth/>  <!-- опционально: включить BLE -->
  </system>
  
  <ui default="/main">
    <!-- страницы -->
  </ui>
  
  <state>
    <!-- переменные -->
  </state>
  
  <timer interval="1000" call="tick"/>
  
  <script language="lua">
    -- код
  </script>
</app>
```

## Виджеты

### label
```xml
<label x="10" y="20" color="#fff">Текст</label>
<label align="center" y="5%" font="48">{variable}</label>
```

### button
```xml
<button x="5%" y="70%" w="90%" h="40" bgcolor="#06f" onclick="doSomething">
  Click me
</button>
<button href="/settings">Settings</button>
```

### slider
```xml
<slider x="5%" y="50%" w="90%" min="0" max="100" bind="brightness"/>
```

### switch
```xml
<switch x="35%" y="34%" bind="enabled" onchange="onToggle"/>
```

### input
```xml
<input x="5%" y="22%" w="90%" h="35" bind="userName" placeholder="Name" onenter="save"/>
```

## State (переменные)

```xml
<state>
  <string name="text" default=""/>
  <int name="count" default="0"/>
  <bool name="enabled" default="false"/>
</state>
```

Доступ из Lua: `state.variableName`

## Биндинг

```xml
<label>{time}</label>              <!-- текст -->
<slider bind="brightness"/>        <!-- двусторонний -->
<button bgcolor="{btnColor}">OK</button>  <!-- атрибут -->
<label visible="{isVisible}">...</label>  <!-- видимость -->
```

## События

- `onclick="func"` — клик
- `onhold="func"` — удержание
- `onchange="func"` — изменение значения
- `onenter="func"` — Enter в input
- `onblur="func"` — потеря фокуса

## Lua API

```lua
-- State
state.varName = "value"
local val = state.varName

-- Навигация
navigate("/page_id")

-- UI
focus("widgetId")
setAttr("id", "bgcolor", "#ff0000")
getAttr("id", "text")

-- Система
print(...)
app_launch("appname")
app_home()
```

## Позиционирование

```xml
<!-- Абсолютные координаты -->
<label x="10" y="20">...</label>

<!-- Проценты -->
<label x="50%" y="10%">...</label>

<!-- Выравнивание -->
<label align="center" y="5%">По центру</label>
<label align="right bottom">Угол</label>
```

## Шрифты

Доступные размеры: 16, 32, 48, 72

```xml
<label font="48">Большой</label>
```

## Цвета

Формат: `#RRGGBB` или `#RGB`

```xml
<label color="#fff" bgcolor="#333">...</label>
```
