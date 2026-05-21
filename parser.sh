#!/usr/bin/env bash                                  # Запускаем скрипт через bash (находит bash через env)
set -euo pipefail                                    # Строгий режим: стоп при ошибке (-e), ошибка при незаданной переменной (-u), ошибки в пайпах не скрываются (pipefail)

INPUT="${1:-urls.txt}"                               # Входной файл: берём 1-й аргумент, если его нет — urls.txt
OUT="report_pretty.csv"                              # Имя выходного CSV-отчёта
TIMEOUT="${TIMEOUT:-12}"                             # Таймаут для curl (сек), если TIMEOUT не задан — 12
UA="${UA:-OSParser/1.0}"                             # User-Agent для запросов, если UA не задан — OSParser/1.0

csv() {                                              # Функция csv(): безопасно печатает значение для CSV
  local s="${1//\"/\"\"}"                            # Заменяем " на "" (экранирование кавычек по правилам CSV)
  s="${s//$'\n'/ }"                                  # Убираем переносы строк, заменяя на пробел (иначе CSV сломается)
  printf "\"%s\"" "$s"                               # Печатаем строку в кавычках "..."
}                                                    # Конец функции csv()

grade() {                                            # Функция grade(): считает score и выдаёт grade+reasons
  local final_url="$1" code="$2" hsts="$3" csp="$4"   # Аргументы: финальный URL, HTTP код, есть ли HSTS (yes/no), есть ли CSP (yes/no)
  local score=100 reasons=()                          # Начинаем со 100 баллов и пустого списка причин

  [[ "$final_url" != https://* ]] && score=$((score-60)) && reasons+=("No HTTPS")   # Если финальный URL не https — минус 60 и причина "No HTTPS"
  [[ "$code" == "000" ]] && score=$((score-40)) && reasons+=("No response")         # Если код 000 (нет ответа/таймаут) — минус 40 и причина
  (( code >= 400 )) && score=$((score-30)) && reasons+=("HTTP $code")               # Если 4xx/5xx — минус 30 и причина с кодом
  [[ "$hsts" == "no" ]] && score=$((score-10)) && reasons+=("No HSTS")              # Если нет HSTS — минус 10 и причина
  [[ "$csp"  == "no" ]] && score=$((score-10)) && reasons+=("No CSP")               # Если нет CSP — минус 10 и причина

  local g                                              # Переменная для текстовой категории grade
  (( score >= 80 )) && g="SAFE-ish" || (( score >= 50 )) && g="MEDIUM" || g="RISK"  # score>=80 SAFE-ish, score>=50 MEDIUM, иначе RISK

  local r                                               # Переменная для строки с причинами
  [[ ${#reasons[@]} -eq 0 ]] && r="OK" || r="$(IFS='; '; echo "${reasons[*]}")"     # Если причин нет — OK, иначе склеиваем причины через "; "
  printf "%s\t%s\t%s" "$g" "$score" "$r"                # Возвращаем grade, score, reasons через табы
}                                                      # Конец функции grade()

echo "\"url\",\"final_url\",\"http_code\",\"redirects\",\"grade\",\"score\",\"reasons\"" > "$OUT"  # Создаём CSV и пишем заголовок колонок (перезаписываем файл)
echo "URL                           CODE  GRADE     SCORE  REASONS"                                 # Заголовок таблицы для вывода в терминал
echo "------------------------------------------------------------"                                 # Разделительная линия для терминала

while IFS= read -r raw; do                            # Читаем входной файл построчно в переменную raw (IFS= и -r — чтобы не портить строку)
  [[ -z "${raw// /}" || "$raw" == \#* ]] && continue   # Пропускаем пустые строки/строки из пробелов и комментарии, начинающиеся с #
  [[ "$raw" != *"://"* ]] && raw="https://$raw"        # Если нет протокола (://), добавляем https://

  meta="$(curl -L -A "$UA" --max-time "$TIMEOUT" -sS -o /dev/null \                 # Запрос curl: следуем редиректам (-L), ставим UA, таймаут, не сохраняем тело (-o /dev/null)
    -w "%{http_code}\t%{num_redirects}\t%{url_effective}" "$raw" 2>/dev/null || \   # -w выводит: http_code, redirects, final url (табами); ошибки скрываем; если curl упал — делаем заглушку
    echo -e "000\t0\t$raw")"                                                        # Заглушка: код 000, редиректы 0, final_url = raw

  IFS=$'\t' read -r code redirects final_url <<<"$meta"                             # Разбиваем meta по табам на code, redirects, final_url

  headers="$(curl -I -L -A "$UA" --max-time "$TIMEOUT" -sS "$final_url" 2>/dev/null | tr -d '\r')" # Берём HTTP-заголовки (-I) с редиректами (-L), убираем \r для корректного grep
  echo "$headers" | grep -qi '^Strict-Transport-Security:' && hsts="yes" || hsts="no"               # Проверяем наличие HSTS заголовка → hsts=yes/no
  echo "$headers" | grep -qi '^Content-Security-Policy:' && csp="yes" || csp="no"                   # Проверяем наличие CSP заголовка → csp=yes/no

  IFS=$'\t' read -r g sc rs <<<"$(grade "$final_url" "$code" "$hsts" "$csp")"        # Вызываем grade() и получаем: g=grade, sc=score, rs=reasons

  printf "%-28s  %-4s  %-8s  %-5s  %s\n" \                                           # Печатаем строку таблицы в терминал с красивыми колонками
    "$(echo "$raw" | sed -E 's#https?://##; s#/.*##')" \                              # Достаём домен из URL: убираем http(s):// и путь после /
    "$code" "$g" "$sc" "$rs"                                                         # Печатаем http code, grade, score, reasons

  {                                                                                  # Начинаем блок формирования одной строки CSV
    csv "$raw"; printf ","                                                           # Колонка 1: исходный URL
    csv "$final_url"; printf ","                                                     # Колонка 2: финальный URL после редиректов
    csv "$code"; printf ","                                                          # Колонка 3: HTTP код
    csv "$redirects"; printf ","                                                     # Колонка 4: количество редиректов
    csv "$g"; printf ","                                                             # Колонка 5: grade (SAFE-ish/MEDIUM/RISK)
    csv "$sc"; printf ","                                                            # Колонка 6: score (0–100)
    csv "$rs"                                                                        # Колонка 7: причины
    printf "\n"                                                                      # Конец строки CSV
  } >> "$OUT"                                                                        # Дописываем строку в файл отчёта (append)

done < "$INPUT"                                   # Заканчиваем цикл и задаём источник строк: читаем из INPUT

echo                                              # Печатаем пустую строку (для красоты)
echo "Done: $OUT"                                  # Сообщаем, что отчёт готов, и показываем имя файла
