#!/bin/bash

# ================= Настройки по умолчанию =================
AUDIO_BITRATE_KB=96  
SCALE="-1:-1"        

# ================= Интерактивный запрос параметров =================

# 1. Запрос пути к файлу
read -p "Введите путь к исходному MP4 файлу: " INPUT_FILE
if [ ! -f "$INPUT_FILE" ]; then
    echo "Ошибка: Файл '$INPUT_FILE' не найден!"
    exit 1
fi

# 2. Запрос лимита размера
read -p "Введите желаемый размер выхода, Mb: " MAX_OUTPUT_SIZE_MB

# 3. Запрос режима скорости (с пресетом по умолчанию)
echo "---------------------------------------------------------"
echo "Выберите режим скорости процессора (0-5):"
echo " 5 - Ультра-быстро (мизерная нагрузка, кодирует мгновенно)"
echo " 1 - Сбалансированно (хорошая точность и средняя скорость)"
echo " 0 - Медленно (максимальное качество сжатия)"
read -p "Введите цифру от 0 до 5 [по умолчанию 2]: " COMPRESSION_PRESET
if [ -z "$COMPRESSION_PRESET" ]; then
    COMPRESSION_PRESET=2 # Оптимальный дефолт для интерактивного режима
fi

# 4. Запрос профиля качества (с пресетом по умолчанию)
echo "---------------------------------------------------------"
echo "Выберите профиль качества:"
echo " cheap - Ультра-дешево (сильное сжатие сразу, без лишних перекодирований)"
echo " auto  - Умный режим (авторасчет под длину видео)"
echo " high  - Максимальная четкость (начинает с высокого качества)"
read -p "Введите профиль (cheap/auto/high) [по умолчанию auto]: " QUALITY_PROFILE
if [ -z "$QUALITY_PROFILE" ]; then
    QUALITY_PROFILE="auto"
fi
echo "---------------------------------------------------------"

# Автоматическое имя выходного файла
OUTPUT_FILE="${INPUT_FILE%.*}.webm"
ABS_OUTPUT_PATH=$(realpath "$OUTPUT_FILE" 2>/dev/null || echo "$(pwd)/$OUTPUT_FILE")

rm -f "$OUTPUT_FILE"

# ================= Логика расчета =================
if ! command -v ffmpeg &> /dev/null || ! command -v ffprobe &> /dev/null || ! command -v bc &> /dev/null; then
    echo "Ошибка: Установите ffmpeg, ffprobe и bc"
    exit 1
fi

DURATION=$(ffprobe -v error -show_entries format=duration -of default/noprint_wrappers=1:nokey=1 "$INPUT_FILE")
TOTAL_BITRATE=$(echo "scale=0; ($MAX_OUTPUT_SIZE_MB * 8192) / $DURATION" | bc)
VIDEO_BITRATE=$(echo "$TOTAL_BITRATE - $AUDIO_BITRATE_KB" | bc)

# Определение стартового CRF
if [ "$QUALITY_PROFILE" = "cheap" ]; then
    START_CRF=45
elif [ "$QUALITY_PROFILE" = "high" ]; then
    START_CRF=22
else
    if [ "$VIDEO_BITRATE" -ge 2000 ]; then START_CRF=24
    elif [ "$VIDEO_BITRATE" -ge 1000 ]; then START_CRF=30
    elif [ "$VIDEO_BITRATE" -ge 500 ]; then START_CRF=36
    else START_CRF=42; fi
fi

echo "============================================="
echo "Параметры сессии:"
echo "Скорость процессора (-speed): $COMPRESSION_PRESET"
echo "Профиль качества: $QUALITY_PROFILE (Стартовый CRF: $START_CRF)"
echo "Итоговый путь: $ABS_OUTPUT_PATH"
echo "Запуск сжатия..."
echo "============================================="

CRF=$START_CRF

# Первый проход кодирования
nice -n 19 ffmpeg -y -i "$INPUT_FILE" \
  -c:v libvpx -crf $CRF -b:v 0 -speed "$COMPRESSION_PRESET" \
  -vf scale="$SCALE" \
  -threads 2 \
  -c:a libvorbis -b:a "${AUDIO_BITRATE_KB}k" -ar 48000 \
  "$OUTPUT_FILE"

# ================= Цикл точной подгонки размера =================
while [ -f "$OUTPUT_FILE" ]; do
    ACTUAL_SIZE_BYTES=$(stat -c%s "$OUTPUT_FILE")
    ACTUAL_SIZE_MB=$(echo "scale=2; $ACTUAL_SIZE_BYTES / 1048576" | bc)
    
    if (( $(echo "$ACTUAL_SIZE_MB <= $MAX_OUTPUT_SIZE_MB" | bc -l) )); then
        break
    fi
    
    if [ "$CRF" -ge 63 ]; then
        echo "Предупреждение: Достигнут максимальный предел сжатия."
        break
    fi

    if [ "$QUALITY_PROFILE" = "cheap" ]; then
        CRF=$((CRF + 6))
    else
        CRF=$((CRF + 3))
    fi
    
    if [ "$CRF" -gt 63 ]; then CRF=63; fi

    echo "---------------------------------------------------------"
    echo "Размер ($ACTUAL_SIZE_MB МБ) выше лимита! Дожимаем с CRF=$CRF..."
    echo "---------------------------------------------------------"
    
    mv "$OUTPUT_FILE" "${OUTPUT_FILE}.tmp"
    nice -n 19 ffmpeg -y -i "${OUTPUT_FILE}.tmp" \
      -c:v libvpx -crf $CRF -b:v 0 -speed "$COMPRESSION_PRESET" \
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
    echo "Обработка завершена успешно!"
    echo "Финальный размер: $ACTUAL_SIZE_MB МБ (Лимит: $MAX_OUTPUT_SIZE_MB МБ)"
    echo "Файл сохранен: $ABS_OUTPUT_PATH"
    echo "============================================="
else
    echo "Ошибка при кодировании файла."
    exit 1
fi
