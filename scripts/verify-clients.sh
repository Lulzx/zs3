#!/bin/sh
set -eu

endpoint="${ZS3_ENDPOINT:-http://127.0.0.1:9000}"
access_key="${ZS3_ACCESS_KEY:-minioadmin}"
secret_key="${ZS3_SECRET_KEY:-minioadmin}"
run_id="$(date +%s)-$$"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zs3-compat.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

for command_name in aws python3 rclone; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "missing required client: $command_name" >&2
        exit 2
    fi
done

if ! python3 -c 'import boto3' >/dev/null 2>&1; then
    echo "missing Python package: boto3 (install with: python3 -m pip install boto3)" >&2
    exit 2
fi

export AWS_ACCESS_KEY_ID="$access_key"
export AWS_SECRET_ACCESS_KEY="$secret_key"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_EC2_METADATA_DISABLED="true"
export ZS3_ENDPOINT="$endpoint"
export ZS3_ACCESS_KEY="$access_key"
export ZS3_SECRET_KEY="$secret_key"

aws_bucket="zs3-aws-$run_id"
printf 'zs3-aws-cli-compatible\n' >"$tmp_dir/aws-input"
aws --endpoint-url "$endpoint" --no-cli-pager s3api create-bucket --bucket "$aws_bucket" >/dev/null
aws --endpoint-url "$endpoint" --no-cli-pager s3api put-object \
    --bucket "$aws_bucket" --key aws-cli/compatibility.txt --body "$tmp_dir/aws-input" >/dev/null
aws --endpoint-url "$endpoint" --no-cli-pager s3api head-object \
    --bucket "$aws_bucket" --key aws-cli/compatibility.txt >/dev/null
aws --endpoint-url "$endpoint" --no-cli-pager s3api get-object \
    --bucket "$aws_bucket" --key aws-cli/compatibility.txt "$tmp_dir/aws-output" >/dev/null
cmp "$tmp_dir/aws-input" "$tmp_dir/aws-output"
aws --endpoint-url "$endpoint" --no-cli-pager s3api delete-object \
    --bucket "$aws_bucket" --key aws-cli/compatibility.txt >/dev/null
aws --endpoint-url "$endpoint" --no-cli-pager s3api delete-bucket --bucket "$aws_bucket" >/dev/null
echo "PASS $(aws --version 2>&1 | cut -d' ' -f1)"

export ZS3_TEST_BUCKET="zs3-boto3-$run_id"
python3 "$(dirname "$0")/verify_boto3.py"

rclone_bucket="zs3-rclone-$run_id"
printf 'zs3-rclone-compatible\n' >"$tmp_dir/rclone-input"
rclone --config "$tmp_dir/rclone.conf" config create zs3 s3 \
    provider Other env_auth false access_key_id "$access_key" \
    secret_access_key "$secret_key" endpoint "$endpoint" \
    region us-east-1 force_path_style true --non-interactive >/dev/null
rclone --config "$tmp_dir/rclone.conf" mkdir "zs3:$rclone_bucket"
rclone --config "$tmp_dir/rclone.conf" copyto \
    "$tmp_dir/rclone-input" "zs3:$rclone_bucket/rclone/compatibility.txt"
rclone --config "$tmp_dir/rclone.conf" cat \
    "zs3:$rclone_bucket/rclone/compatibility.txt" >"$tmp_dir/rclone-output"
cmp "$tmp_dir/rclone-input" "$tmp_dir/rclone-output"
rclone --config "$tmp_dir/rclone.conf" lsf "zs3:$rclone_bucket/rclone" \
    | grep -qx 'compatibility.txt'
rclone --config "$tmp_dir/rclone.conf" deletefile \
    "zs3:$rclone_bucket/rclone/compatibility.txt"
rclone --config "$tmp_dir/rclone.conf" rmdir "zs3:$rclone_bucket"
echo "PASS rclone $(rclone version | sed -n '1s/^rclone v//p')"

echo "All three S3 clients are compatible with $endpoint"
