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

rm -f "$OUTPUT_FILE"

# ================= Логика расчета =================
if ! command -v ffmpeg &> /dev/null || ! command -v ffprobe &> /dev/null || ! command -v bc &> /dev/null; then
    echo "Ошибка: Установите ffmpeg, ffprobe и bc"
    exit 1
fi

# Узнаем длительность видео в секундах
DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE")

# Рассчитываем примерный битрейт, который ОЖИДАЕТСЯ для такого размера
TOTAL_BITRATE=$(echo "scale=0; ($MAX_OUTPUT_SIZE_MB * 8192) / $DURATION" | bc)
VIDEO_BITRATE=$(echo "$TOTAL_BITRATE - $AUDIO_BITRATE_KB" | bc)

# Динамически выбираем стартовый CRF в зависимости от целевого битрейта
# Чем меньше битрейт нам нужен, тем выше (агрессивнее) должен быть стартовый CRF
if [ "$VIDEO_BITRATE" -ge 2000 ]; then
    START_CRF=24
elif [ "$VIDEO_BITRATE" -ge 1000 ]; then
    START_CRF=30
elif [ "$VIDEO_BITRATE" -ge 500 ]; then
    START_CRF=36
else
    START_CRF=42
fi

echo "============================================="
echo "Длительность видео: $DURATION сек."
echo "Рекомендуемый стартовый CRF: $START_CRF"
echo "Запуск первого сжатия..."
echo "============================================="

CRF=$START_CRF
nice -n 19 ffmpeg -y -i "$INPUT_FILE" \
  -c:v libvpx -crf $CRF -b:v 0 \
  -vf scale="$SCALE" \
  -threads 2 \
  -c:a libvorbis -b:a "${AUDIO_BITRATE_KB}k" -ar 48000 \
  "$OUTPUT_FILE"

# ================= Цикл точной подгонки размера =================
while [ -f "$OUTPUT_FILE" ]; do
    ACTUAL_SIZE_BYTES=$(stat -c%s "$OUTPUT_FILE")
    ACTUAL_SIZE_MB=$(echo "scale=2; $ACTUAL_SIZE_BYTES / 1048576" | bc)
    
    # Если файл уложился в лимит — выходим из цикла
    if (( $(echo "$ACTUAL_SIZE_MB <= $MAX_OUTPUT_SIZE_MB" | bc -l) )); then
        break
    fi
    
    # Если дошли до максимального CRF=63 и все равно не влезли — останавливаемся
    if [ "$CRF" -ge 63 ]; then
        echo "Предупреждение: Достигнут предел сжатия. Видео слишком длинное для такого размера."
        break
    fi

    # Увеличиваем CRF на 4 пункта для следующей попытки дожатия
    CRF=$((CRF + 4))
    if [ "$CRF" -gt 63 ]; then CRF=63; fi

    echo "---------------------------------------------------------"
    echo "Размер ($ACTUAL_SIZE_MB МБ) выше лимита! Дожимаем с CRF=$CRF..."
    echo "---------------------------------------------------------"
    
    mv "$OUTPUT_FILE" "${OUTPUT_FILE}.tmp"
    nice -n 19 ffmpeg -y -i "${OUTPUT_FILE}.tmp" \
      -c:v libvpx -crf $CRF -b:v 0 \
      -threads 2 \
      -c:a copy \
      "$OUTPUT_FILE"
    
    rm "${OUTPUT_FILE}.tmp"
done

# ================= Финал =================
if [ -f "$OUTPUT_FILE" ]; then
    ACTUAL_SIZE_BYTES=$(stat -c%s "$OUTPUT_FILE")
    ACTUAL_SIZE_MB=$(echo "scale=2; $ACTUAL_SIZE_BYTES / 1048576" | bc)
    
    echo "============================================="
    echo "Идеально подогнано!"
    echo "Финальный размер: $ACTUAL_SIZE_MB МБ (Лимит: $MAX_OUTPUT_SIZE_MB МБ)"
    echo "Путь: $ABS_OUTPUT_PATH"
    echo "============================================="
else
    echo "Ошибка при кодировании файла."
    exit 1
fi
