"""Build the bundled, offline Russian policy; no network or user data access."""
from pathlib import Path
from shutil import copyfile

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, PageBreak

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "output/pdf/kenai-privacy-policy-ru.pdf"
ASSET = ROOT / "apps/desktop/assets/legal/privacy-policy-ru.pdf"
for path in (OUTPUT, ASSET):
    path.parent.mkdir(parents=True, exist_ok=True)
pdfmetrics.registerFont(TTFont("Policy", "C:/Windows/Fonts/arial.ttf"))
pdfmetrics.registerFont(TTFont("PolicyBold", "C:/Windows/Fonts/arialbd.ttf"))
pdfmetrics.registerFontFamily("Policy", normal="Policy", bold="PolicyBold")
INK = colors.HexColor("#202331")
ACCENT = colors.HexColor("#5655d9")
BODY = ParagraphStyle("Body", fontName="Policy", fontSize=10.4, leading=15,
                      textColor=INK, spaceAfter=10, alignment=TA_LEFT)
HEADING = ParagraphStyle("Heading", parent=BODY, fontName="PolicyBold",
                         fontSize=12, leading=17, spaceBefore=9, spaceAfter=6)
TITLE = ParagraphStyle("Title", parent=HEADING, fontSize=25, leading=30,
                       textColor=ACCENT, spaceBefore=0, spaceAfter=14)
NOTE = ParagraphStyle("Note", parent=BODY, fontSize=9.2, leading=13,
                      textColor=colors.HexColor("#555967"))
story = []

def p(text, style=BODY):
    story.append(Paragraph(text, style))

def section(title, text):
    p(title, HEADING)
    p(text)

def footer(canvas, doc):
    canvas.saveState()
    canvas.setStrokeColor(colors.HexColor("#dedee9"))
    canvas.line(48, 43, A4[0] - 48, 43)
    canvas.setFont("Policy", 8)
    canvas.setFillColor(colors.HexColor("#666a78"))
    canvas.drawString(48, 29, "Kenai VPN | Базовая редакция от 18.09.2026")
    canvas.drawRightString(A4[0] - 48, 29, f"{doc.page}")
    canvas.restoreState()

p("Kenai VPN", NOTE)
p("Политика<br/>конфиденциальности", TITLE)
p("<b>Владелец сервиса:</b> Царан Павел Андреевич.<br/>"
  "<b>Редакция:</b> 18 сентября 2026 года.")
p("Базовая редакция для Windows-приложения. Документ описывает текущую "
  "клиентскую реализацию. Контакт поддержки, конкретные сроки хранения и "
  "порядок обработки данных на серверах требуют подтверждения владельцем "
  "перед публичным выпуском.", NOTE)
section("1. Какие данные использует приложение",
        "Для активации используются персональный 12-значный ключ, данные "
        "аккаунта и подписки, а также параметры доступа к VPN. Для работы "
        "интерфейса сохраняются выбранный сервер, протокол и настройки "
        "приложения. Ключ доступа является конфиденциальным: не передавайте "
        "его третьим лицам и не включайте в публичные обращения.")
section("2. Для чего нужны эти данные",
        "Проверка доступа к сервису, получение профилей подключения, создание "
        "VPN-соединения, сохранение пользовательских настроек и диагностика "
        "неисправностей. Автоматическое подключение, трей и автозапуск "
        "используют локальные настройки и сами по себе не являются "
        "согласием на рекламные рассылки или передачу диагностических архивов.")
section("3. Локальное хранение и диагностика",
        "Данные авторизации хранятся средствами защищённого хранилища "
        "Windows; профили служба хранит в защищённом виде. Приложение "
        "создаёт локальные технические журналы. Перед экспортом диагностики "
        "известные секреты скрываются, однако архив стоит проверить перед "
        "передачей. Текущая версия не отправляет диагностику автоматически: "
        "переключатель согласия сохраняет локальное предпочтение, а экспорт "
        "архива выполняется по отдельному действию пользователя.")
story.append(PageBreak())
p("Передача данных и ваш контроль", TITLE)
section("4. Что происходит при подключении",
        "Приложение обращается к API сервиса для активации и получения "
        "параметров доступа, а затем к выбранному VPN-серверу. Проверка ping "
        "создаёт отдельное сетевое обращение. VPN-серверу технически доступны "
        "сетевой адрес подключения и служебные характеристики сеанса. "
        "Настоящий документ не заявляет политику «без логов»: состав и сроки "
        "хранения серверных журналов пока не подтверждены.")
section("5. Защита трафика и ограничения",
        "VPN защищает участок связи между устройством и VPN-сервером. "
        "Он не заменяет HTTPS, защиту устройства и правила безопасности "
        "при работе с аккаунтами. Сайты, приложения, интернет-провайдеры "
        "и инфраструктурные поставщики могут обрабатывать данные в своей "
        "части соединения по собственным правилам. Абсолютная анонимность "
        "и отсутствие любых технических журналов не гарантируются.")
section("6. Удаление и сроки хранения",
        "Выход из аккаунта удаляет локальные данные авторизации. Это не "
        "равнозначно удалению данных аккаунта и журналов на сервере. "
        "Настройки и локальные журналы могут сохраняться до очистки или "
        "удаления приложения. Для серверных данных необходим отдельный "
        "регламент владельца; неподтверждённые сроки в этой редакции "
        "не указываются.")
section("7. Обращения владельцу и изменения политики",
        "Вы можете обратиться к владельцу по вопросам доступа, исправления "
        "и удаления данных, а также ограничения их обработки в пределах "
        "применимого законодательства. Владелец: Царан Павел Андреевич. "
        "Отдельный контакт для таких обращений пока не опубликован; "
        "запросите его у владельца до передачи дополнительных персональных "
        "данных. Не отправляйте секретный ключ в открытых сообщениях. "
        "Обновлённая редакция политики распространяется вместе с "
        "обновлением приложения и содержит новую дату.")
p("Этот PDF включён в приложение и открывается локально, без загрузки "
  "документа с сайта и без передачи данных внешнему PDF-сервису.", NOTE)
SimpleDocTemplate(str(OUTPUT), pagesize=A4, leftMargin=48, rightMargin=48,
                  topMargin=42, bottomMargin=58, title="Kenai VPN - Политика конфиденциальности",
                  author="Царан Павел Андреевич").build(story, onFirstPage=footer, onLaterPages=footer)
copyfile(OUTPUT, ASSET)
print(OUTPUT)
