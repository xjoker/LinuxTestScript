#!/bin/bash
# https://github.com/xjoker/LinuxTestScript

# 设置默认值
DEFAULT_SIZE="1G"
DEFAULT_SEQ_TIME=30
DEFAULT_RAND_TIME=60

# 参数处理
if [ $# -eq 0 ]; then
    TEST_FILE=$(mktemp -u)
    SIZE=$DEFAULT_SIZE
    SEQ_TIME=$DEFAULT_SEQ_TIME
    RAND_TIME=$DEFAULT_RAND_TIME
elif [ "$#" -ge 1 ] && [ "$#" -le 4 ]; then
    TEST_FILE="$1"
    SIZE="${2:-$DEFAULT_SIZE}"
    if [ "$#" -eq 3 ]; then
        SEQ_TIME="$3"
        RAND_TIME="$3"
    elif [ "$#" -eq 4 ]; then
        SEQ_TIME="$3"
        RAND_TIME="$4"
    else
        SEQ_TIME=$DEFAULT_SEQ_TIME
        RAND_TIME=$DEFAULT_RAND_TIME
    fi
else
    echo "使用方法: $0 [测试文件路径] [测试大小] [顺序测试时间] [随机测试时间]"
    echo "测试大小: 可选,默认为 $DEFAULT_SIZE"
    echo "顺序测试时间: 可选,默认为 ${DEFAULT_SEQ_TIME}秒"
    echo "随机测试时间: 可选,默认为 ${DEFAULT_RAND_TIME}秒"
    echo "例如: $0"
    echo "或者: $0 /mnt/mydisk/testfile"
    echo "或者: $0 /mnt/mydisk/testfile 2G"
    echo "或者: $0 /mnt/mydisk/testfile 2G 45"
    echo "或者: $0 /mnt/mydisk/testfile 2G 30 60"
    exit 1
fi

# 验证并修正参数
if [[ ! $SIZE =~ ^[0-9]+[KMGT]?$ ]]; then
    echo "警告: 无效的测试大小 '$SIZE',使用默认值 $DEFAULT_SIZE"
    SIZE=$DEFAULT_SIZE
fi

if ! [[ "$SEQ_TIME" =~ ^[0-9]+$ ]]; then
    echo "警告: 无效的顺序测试时间 '$SEQ_TIME',使用默认值 $DEFAULT_SEQ_TIME"
    SEQ_TIME=$DEFAULT_SEQ_TIME
fi

if ! [[ "$RAND_TIME" =~ ^[0-9]+$ ]]; then
    echo "警告: 无效的随机测试时间 '$RAND_TIME',使用默认值 $DEFAULT_RAND_TIME"
    RAND_TIME=$DEFAULT_RAND_TIME
fi

# 确保以root权限运行
if [ "$EUID" -ne 0 ]; then
    echo "请以root权限运行此脚本"
    exit 1
fi

# 检查是否安装了所需的命令
for cmd in fio jq; do
    if ! command -v $cmd &> /dev/null; then
        echo "$cmd 未安装。正在安装..."
        apt-get update && apt-get install -y $cmd
    fi
done

# 进度条函数
progress_bar() {
    local duration=$1
    local elapsed=0
    local width=50
    local char_done="#"
    local char_todo="-"

    while [ $elapsed -lt $duration ]; do
        local percent=$((elapsed * 100 / duration))
        local done=$((elapsed * width / duration))
        local todo=$((width - done))
        local eta=$((duration - elapsed))

        printf "\r[%${done}s%${todo}s] %3d%% 已用时间: %02d:%02d 预计剩余: %02d:%02d" \
               "${char_done:0:done}" "${char_todo:0:todo}" \
               "${percent}" $((elapsed / 60)) $((elapsed % 60)) \
               $((eta / 60)) $((eta % 60))
        
        sleep 1
        ((elapsed++))
    done
    printf "\r%$(tput cols)s\r"  # 清除整行
}

# 格式化带宽函数
format_bandwidth() {
    local bw=$1
    if (( bw >= 1000000 )); then
        printf "%.2f GB/s" "$(echo "scale=2; $bw / 1000000" | bc)"
    elif (( bw >= 1000 )); then
        printf "%.2f MB/s" "$(echo "scale=2; $bw / 1000" | bc)"
    else
        printf "%.2f KB/s" "$bw"
    fi
}

# 定义测试函数
run_test() {
    local rw=$1
    local bs=$2
    local iodepth=$3
    local numjobs=${4:-1}
    local test_name=$5
    local runtime=$6
    
    echo "$test_name: $bs $rw - 测试时间: ${runtime}秒 "
    
    fio --name=test --filename=$TEST_FILE --ioengine=libaio --direct=1 \
        --rw=$rw --bs=$bs --iodepth=$iodepth --numjobs=$numjobs \
        --size=$SIZE --runtime=$runtime --time_based --group_reporting \
        --output-format=json --output="${test_name}_result.json" \
        --status-interval=3600 > /dev/null 2>&1 &
    
    local fio_pid=$!
    progress_bar $runtime
    wait $fio_pid
    
    local result=$(cat "${test_name}_result.json")
    
    read_bw=$(echo "$result" | jq -r '.jobs[0].read.bw')
    write_bw=$(echo "$result" | jq -r '.jobs[0].write.bw')
    read_iops=$(echo "$result" | jq -r '.jobs[0].read.iops')
    write_iops=$(echo "$result" | jq -r '.jobs[0].write.iops')

    echo -n "结果: "
    if [[ -n "$read_bw" && "$read_bw" != "0" ]]; then
        echo -n "读取: $(format_bandwidth $read_bw)  "
        if [[ -n "$read_iops" && "$read_iops" != "0" ]]; then
            echo -n "读取IOPS: ${read_iops%.*}"
        fi
    fi
    
    if [[ -n "$write_bw" && "$write_bw" != "0" ]]; then
        [ "$read_bw" != "0" ] && echo -n "  "
        echo -n "写入: $(format_bandwidth $write_bw)  "
        if [[ -n "$write_iops" && "$write_iops" != "0" ]]; then
            echo -n "写入IOPS: ${write_iops%.*}"
        fi
    fi
    
    echo
    rm "${test_name}_result.json"
}

# 主测试逻辑
main() {
    local start_time=$(date -u "+%Y-%m-%d %H:%M:%S UTC")
    local fio_version=$(fio --version)
    echo "磁盘性能测试[20240823]"
    echo "======================================"
    echo ""
    echo "参数说明:"
    echo "1. 测试文件路径: 指定进行读写测试的文件位置"
    echo "2. 测试大小: 指定测试文件的大小,默认为 $DEFAULT_SIZE"
    echo "3. 顺序测试时间: 指定顺序测试的运行时间,默认为 ${DEFAULT_SEQ_TIME} 秒"
    echo "4. 随机测试时间: 指定随机测试的运行时间,默认为 ${DEFAULT_RAND_TIME} 秒"
    echo ""
    echo "测试逻辑说明:"
    echo "1. SEQ1M Q8T1: 1MB 顺序读写,队列深度=8,线程=1"
    echo "2. 4KQ32T1: 4KB 随机读写,队列深度=32,线程=1"
    echo "3. 4KQ1T1: 4KB 随机读写,队列深度=1,线程=1"
    echo ""
    echo "使用方法: ./disk_test.sh [测试文件路径] [测试大小] [顺序测试时间] [随机测试时间]"
    echo "测试大小: 可选,默认为 $DEFAULT_SIZE"
    echo "顺序测试时间: 可选,默认为 ${DEFAULT_SEQ_TIME}秒"
    echo "随机测试时间: 可选,默认为 ${DEFAULT_RAND_TIME}秒"
    echo "或者: ./disk_test.sh /mnt/mydisk/testfile"
    echo "或者: ./disk_test.sh /mnt/mydisk/testfile 2G"
    echo "或者: ./disk_test.sh /mnt/mydisk/testfile 2G 45"
    echo "或者: ./disk_test.sh /mnt/mydisk/testfile 2G 30 60"
    echo ""
    echo "每项测试都进行读和写两个阶段。"
    echo ""
    echo "======================================"
    echo "测试开始时间: $start_time"
    echo "测试文件: $TEST_FILE"
    echo "测试大小: $SIZE"
    echo "顺序测试时间: ${SEQ_TIME}秒"
    echo "随机测试时间: ${RAND_TIME}秒"
    echo ""
    echo "测试软件: Flexible I/O Tester (fio)"
    echo "fio 版本: $fio_version"
    echo ""
    echo "当前使用的参数:"
    echo "- 测试文件路径: $TEST_FILE"
    echo "- 测试大小: $SIZE"
    echo "- 顺序测试时间: ${SEQ_TIME}秒"
    echo "- 随机测试时间: ${RAND_TIME}秒"
    echo "======================================"
    
    for test_config in \
        "read 1M 8 1 SEQ1M $SEQ_TIME" \
        "write 1M 8 1 SEQ1M $SEQ_TIME" \
        "read 4K 32 1 4KQ32T1 $SEQ_TIME" \
        "write 4K 32 1 4KQ32T1 $SEQ_TIME" \
        "read 4K 1 1 4KQ1T1 $SEQ_TIME" \
        "write 4K 1 1 4KQ1T1 $SEQ_TIME" \
        "randread 4K 32 1 4KQ32T1 $RAND_TIME" \
        "randwrite 4K 32 1 4KQ32T1 $RAND_TIME"
    do
        run_test $test_config
        echo "------------------------------------"
    done

    # 清理测试文件
    rm -f $TEST_FILE

    local end_time=$(date -u "+%Y-%m-%d %H:%M:%S UTC")
    echo "测试结束时间: $end_time"
    echo "测试完成。"
    echo "======================================"
}

# 执行主函数
main
