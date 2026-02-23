## СТРУКТУРА ПРИЛОЖЕНИЯ

```xml
<app os="1.0" title="myapp">
  <ui default="/main">
    <page id="main">
      <!-- виджеты -->
    </page>
  </ui>
  
  <state>
    <string name="var1" default=""/>
    <int name="count" default="0"/>
    <bool name="flag" default="false"/>
  </state>
  
  <timer interval="1000" call="tick"/>
  
  <script language="lua">
    function tick()
      state.count = state.count + 1
    end
  </script>
</app>
```

## ВИДЖЕТЫ

- `<label x="10%" y="20%" color="#fff">{text}</label>` — текст с биндингом
- `<button onclick="fn">Text</button>` или `<button href="/page">`
- `<input bind="var" placeholder="..." onenter="fn"/>`
- `<slider bind="var" min="0" max="100"/>`
- `<switch bind="var" onchange="fn"/>`
- `<image src="icon.png"/>` — изображение

**`<canvas>` — НЕ ИСПОЛЬЗОВАТЬ** (сырой, плохо работает на слабых устройствах)

## ВЛОЖЕННЫЕ LABEL В BUTTON

Один `<label>` внутри `<button>` — его текст/font/color применяются к кнопке:
```xml
<button onclick="num7"><label font="22" color="#FFF">7</label></button>
<!-- ОК — кнопка покажет "7" с font=22, color=#FFF -->
```

**Несколько `<label>` — только первый используется, остальные игнорируются!**
```xml
<button>
  <label>Title</label>
  <label>Value</label>  <!-- ИГНОРИРУЕТСЯ! -->
</button>
```

Для карточек используй плоскую структуру с z-index.

## OVERFLOW (для label)

Управляет поведением текста при переполнении. **Работает только с заданной шириной (w).**

| overflow | Поведение |
|----------|-----------|
| `wrap` | Перенос на следующую строку (DEFAULT) |
| `ellipsis` | Обрезка с ... |
| `clip` | Жёсткая обрезка |
| `scroll` | Бегущая строка |

```xml
<label w="80%" overflow="ellipsis">Длинный текст...</label>
<label w="80%" h="60" overflow="wrap">Многострочный текст</label>
<label w="70%" overflow="scroll">🎵 Now Playing: Long Title</label>
```

## ПОЗИЦИОНИРОВАНИЕ

- x, y, w, h — в процентах ("50%") или пикселях (100)
- **Предпочитай проценты** — адаптивнее
- align="center" или align="center center" — выравнивание элемента
- text-align="center" — выравнивание текста внутри

## LUA API

- state.varName — чтение/запись состояния
- navigate("/pageId") — переход на страницу
- focus("widgetId") — фокус на input (открывает клавиатуру)
- setAttr(id, "attr", "value") / getAttr(id, "attr")
