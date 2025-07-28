#!/bin/bash
# shellcheck disable=SC2086
set -e

# 获取脚本所在目录（避免相对路径错误）
workfile="$(cd "$(dirname "$0")" && pwd)"
ExtractErofs="$workfile/common/binary/extract.erofs"
chmod +x $ExtractErofs
ImageExtRactorLinux="$workfile/common/binary/imgextractorLinux"
chmod u+wx "$ImageExtRactorLinux"

# 工作目录和输出目录
TMPDir="$workfile/tmp/"
DistDir="$workfile/dist/"
payload_img_dir="${TMPDir}payload_img/"
pre_patch_file_dir="${TMPDir}pre_patch_file/"
patch_mods_dir="${TMPDir}patch_mods/"
release_dir="${TMPDir}release/"
batch_config_file="$workfile/batch_rom_list.txt"
batch_output_dir="$workfile/batch_dist"

# 参数初始化
input_rom_version=""
input_rom_url=""
input_android_target_version="15"  # 默认值
input_image_fs="erofs"             # 新增：镜像解压方式，默认是 erofs

# 处理批量模式
if [[ "$1" == "--batch" ]]; then

  echo "🧹 清理旧的 batch 输出目录: $batch_output_dir"
  sudo rm -rf "$batch_output_dir"
  mkdir -p "$batch_output_dir"

  if [[ ! -f "$batch_config_file" ]]; then
    echo "❌ 批量构建配置文件不存在: $batch_config_file" >&2
    exit 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue

    echo "🚀 开始处理: $line"
    bash "$0" $line

    rom_version=$(echo "$line" | grep -oP '(?<=--rom\s)[^ ]+')
    device_name=$(echo "$line" | grep -oP '(?<=--device\s)[^ ]+')

    if [[ -z "$device_name" ]]; then
      echo "❌ 错误：批量构建中的这一行缺少 --device 参数：" >&2
      echo "   $line" >&2
      echo "请为每个 ROM 配置添加 --device <设备名>" >&2
      exit 1
    fi

    if [[ -f "$DistDir${rom_version}.zip" ]]; then
      mkdir -p "$batch_output_dir/$device_name"
      mv "$DistDir${rom_version}.zip" "$batch_output_dir/$device_name/${rom_version}.zip"
      echo "📁 构建结果已移动到: $batch_output_dir/$device_name/${rom_version}.zip"
    else
      echo "⚠️ 未找到输出文件: $DistDir${rom_version}.zip"
    fi
  done < "$batch_config_file"

  echo "✅ 批量构建完成"
  exit 0
fi


# 参数解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rom)
      input_rom_version="$2"
      shift 2
      ;;
    --url)
      input_rom_url="$2"
      shift 2
      ;;
    --android)
      input_android_target_version="$2"
      shift 2
      ;;
    --fs)
      input_image_fs="$2"
      shift 2
      ;;
    *)
      echo "❌ 未知参数: $1"
      exit 1
      ;;
  esac
done


# 批量模式
if [[ "$1" == "--batch" ]]; then
  if [[ ! -f "$batch_config_file" ]]; then
    echo "❌ 批量构建配置文件不存在: $batch_config_file" >&2
    exit 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    # 跳过空行或注释
    [[ -z "$line" || "$line" == \#* ]] && continue

    echo "🚀 开始处理: $line"
    bash "$0" $line

    # 提取 ROM 版本号用于文件夹命名
    rom_version=$(echo "$line" | grep -oP '(?<=--rom\s)[^ ]+')
    if [[ -f "$DistDir${rom_version}.zip" ]]; then
      mkdir -p "$batch_output_dir/$rom_version"
      mv "$DistDir${rom_version}.zip" "$batch_output_dir/$rom_version/${rom_version}.zip"
      echo "📁 构建结果已移动到: $batch_output_dir/$rom_version/"
    else
      echo "⚠️ 未找到预期的输出文件: $DistDir${rom_version}.zip"
    fi
  done < "$batch_config_file"

  echo "✅ 批量构建完成"
  exit 0
fi


# 检查必须参数
if [[ -z "$input_rom_version" || -z "$input_rom_url" ]]; then
  echo "❌ 错误：必须提供 --rom 和 --url 参数。" >&2
  echo "用法：bash ./build.sh --rom <ROM_VERSION> --url <ROM_URL> [--android <ANDROID_VERSION>]" >&2
  exit 1
fi

# 校验 Android 版本，目前仅支持 14 和 15，保留未来扩展空间
case "$input_android_target_version" in
  14|15)
    # 支持的版本，继续执行
    ;;
  *)
    echo "❌ 错误：不支持的 Android 版本：$input_android_target_version，仅支持 14 或 15。" >&2
    exit 1
    ;;
esac

# 检查镜像格式是否合法
if [[ "$input_image_fs" != "erofs" && "$input_image_fs" != "ext4" ]]; then
  echo "❌ 镜像解压方式仅支持 erofs 或 ext4，当前为: $input_image_fs"
  exit 1
fi


echo "🧹 清理并准备临时目录..."
sudo rm -rf "$TMPDir"
mkdir -p "$TMPDir" "$DistDir" "$payload_img_dir" "$pre_patch_file_dir" "$patch_mods_dir" "$release_dir"

echo "🔍 检查 payload_dumper 是否可用..."
if ! command -v payload_dumper >/dev/null 2>&1; then
  echo "❌ 错误：payload_dumper 未安装或不在 PATH 中。" >&2
  echo "请安装它，例如：" >&2
  echo "  pipx install git+https://github.com/5ec1cff/payload-dumper" >&2
  exit 1
fi

echo "⬇️ 获取 system_ext.img..."
payload_dumper --partitions system_ext --out "$payload_img_dir" "$input_rom_url"

if [ ! -f "${payload_img_dir}system_ext.img" ]; then
  echo "❌ 找不到 system_ext.img" >&2
  exit 1
fi

# 根据镜像格式选择工具
if [[ "$input_image_fs" == "erofs" ]]; then
  echo "📦 使用 extract.erofs 解包 system_ext.img..."
  "$ExtractErofs" \
    -i "${payload_img_dir}system_ext.img" \
    -x -c "$workfile/common/system_ext_unpak_list.txt" \
    -o "$pre_patch_file_dir"

elif [[ "$input_image_fs" == "ext4" ]]; then
  echo "📦 使用 imgextractorLinux 解包 system_ext.img..."
  sudo "$ImageExtRactorLinux" "${payload_img_dir}system_ext.img" "$pre_patch_file_dir"
else
  echo "❌ 不支持的镜像解压方式: $input_image_fs"
  exit 1
fi

# 检查提取文件
system_ext_unpak_list_file="$workfile/common/system_ext_unpak_list.txt"
echo "✅ 校验解包文件是否提取成功..."

if [ ! -f "$system_ext_unpak_list_file" ]; then
  echo "❌ 缺失列表文件: $system_ext_unpak_list_file" >&2
  exit 1
fi

while IFS= read -r line || [[ -n "$line" ]]; do
  file=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$file" ] && continue

  full_path="${pre_patch_file_dir}system_ext${file}"

  echo "🔍 检查文件: $full_path"

  if [ ! -f "$full_path" ]; then
    echo "❌ 缺失文件: system_ext${file}" >&2
    exit 1
  fi
done < "$system_ext_unpak_list_file"

echo "📁 复制补丁模组源码..."
cp -a "$workfile/mods/." "$patch_mods_dir"

echo "🛠️ 修补 miui-services.jar..."
cp -f "${pre_patch_file_dir}system_ext/framework/miui-services.jar" "${patch_mods_dir}/miui-services-Smali/miui-services.jar"
bash "${patch_mods_dir}/miui-services-Smali/run.sh" "$input_android_target_version"

echo "🛠️ 修补 MiuiSystemUI.apk..."
cp -f "${pre_patch_file_dir}system_ext/priv-app/MiuiSystemUI/MiuiSystemUI.apk" "${patch_mods_dir}/MiuiSystemUISmali/MiuiSystemUI.apk"
bash "${patch_mods_dir}/MiuiSystemUISmali/run.sh" "$input_android_target_version"

patched_files=(
  "miui-services-Smali/miui-services_out.jar"
  "MiuiSystemUISmali/MiuiSystemUI_out.apk"
)

echo "✅ 校验修补结果..."
for file in "${patched_files[@]}"; do
  if [ ! -f "${patch_mods_dir}${file}" ]; then
    echo "❌ 缺失补丁结果文件: ${file}" >&2
    exit 1
  fi
done

echo "📦 构建最终模块目录..."
cp -a "$workfile/module_src/." "$release_dir"

mkdir -p "${release_dir}system/system_ext/framework/"
cp -f "${patch_mods_dir}miui-services-Smali/miui-services_out.jar" "${release_dir}system/system_ext/framework/miui-services.jar"

mkdir -p "${release_dir}system/system_ext/priv-app/MiuiSystemUI/"
cp -f "${patch_mods_dir}MiuiSystemUISmali/MiuiSystemUI_out.apk" "${release_dir}system/system_ext/priv-app/MiuiSystemUI/MiuiSystemUI.apk"

echo "📝 更新 module.prop 中的版本号..."
sed -i "s/^version=.*/version=${input_rom_version}/" "${release_dir}module.prop"

echo "📝 更新 system.prop 移除不兼容的配置"
if [ "$input_android_target_version" -eq 14 ]; then
  sed -i '/^ro\.config\.sothx_project_treble_support_vertical_screen_split/d' "${release_dir}system.prop"
  sed -i '/^ro\.config\.sothx_project_treble_vertical_screen_split_version/d' "${release_dir}system.prop"
fi

final_zip="${DistDir}${input_rom_version}.zip"
echo "📦 打包为 Magisk 模块：$final_zip"
cd "$release_dir"
zip -r "$final_zip" ./*
cd "$workfile"

echo "✅ 构建完成：$final_zip"
