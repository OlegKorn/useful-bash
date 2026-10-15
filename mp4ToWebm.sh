#!/bin/bash

# ================= Настройки сжатия =================
AUDIO_BITRATE_KB=96  
SCALE="-1:-1"        

# ================= Интерактивный запрос =================
read -p "Введите путь к исходному MP4 файлу: " INPUT_FILE

if [ ! -f "$INPUT_FILE" ]; then
    echo "Ошибка: Файл '$INPUT_FILE' не найден!"
    exit 1
fi

read -p "Введите желаемый размер выхода, Mb: " MAX_OUTPUT_SIZE_MB

OUTPUT_FILE="${INPUT_FILE%.*}.webm"
ABS_OUTPUT_PATH=$(realpath "$OUTPUT_FILE" 2>/dev/null || echo "$(pwd)/$OUTPUT_FILE")

# Удаляем старый файл, если он остался от прошлых попыток
rm -f "$OUTPUT_FILE"

echo "============================================="
echo "Запуск сжатия в один проход (без зависаний)..."
echo "Итоговый файл будет сохранен в: $ABS_OUTPUT_PATH"
echo "============================================="

# Запускаем стабильное однопроходное сжатие. 
# -crf 36 дает сильное сжатие (отлично подходит под лимит 15МБ)
# -threads 2 и nice -n 19 защищают процессор от перегрузки
nice -n 19 ffmpeg -y -i "$INPUT_FILE" \
  -c:v libvpx -crf 36 -b:v 0 \
  -vf scale="$SCALE" \
  -threads 2 \
  -c:a libvorbis -b:a "${AUDIO_BITRATE_KB}k" -ar 48000 \
  "$OUTPUT_FILE"

# Проверяем, создался ли файл
if [ $? -eq 0 ] && [ -f "$OUTPUT_FILE" ]; then
    # Получаем реальный размер созданного файла в мегабайтах
    ACTUAL_SIZE_BYTES=$(stat -c%s "$OUTPUT_FILE")
    ACTUAL_SIZE_MB=$(echo "scale=2; $ACTUAL_SIZE_BYTES / 1048576" | bc)

    echo "============================================="
    echo "Кодирование завершено!"
    echo "Полученный размер файла: $ACTUAL_SIZE_MB МБ (Лимит: $MAX_OUTPUT_SIZE_MB МБ)"
    
    # Проверка: если файл всё же превысил лимит, жмем сильнее автоматически
    if (( $(echo "$ACTUAL_SIZE_MB > $MAX_OUTPUT_SIZE_MB" | bc -l) )); then
        echo "Файл превысил лимит. Запускаем быстрое дожатие..."
        mv "$OUTPUT_FILE" "${OUTPUT_FILE}.tmp"
        nice -n 19 ffmpeg -y -i "${OUTPUT_FILE}.tmp" -c:v libvpx -crf 46 -b:v 0 -threads 2 -c:a copy "$OUTPUT_FILE"
        rm "${OUTPUT_FILE}.tmp"
    fi

    echo "Файл успешно сохранен: $ABS_OUTPUT_PATH"
    echo "============================================="
else
    echo "============================================="
    echo "ОШИБКА: FFmpeg не смог обработать файл."
    echo "============================================="
    exit 1
fi
