#!/usr/bin/env bash

# Exit on any error
set -e

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVITES_DIR="$(dirname "${SCRIPT_DIR}")"

# Output directory for generated Swift files
OUTPUT_DIR="${INVITES_DIR}"

echo "🔧 Generating Swift code from Protocol Buffer definitions..."

# Check if protoc is installed
if ! command -v protoc &> /dev/null; then
    echo "❌ protoc is not installed. Please install Protocol Buffers compiler:"
    echo "   brew install protobuf"
    exit 1
fi

# Check if swift-protobuf plugin is installed
if ! command -v protoc-gen-swift &> /dev/null; then
    echo "❌ swift-protobuf is not installed. Please run:"
    echo "   make setup"
    exit 1
fi

# Generate Swift code from all .proto files in this directory
for proto_file in "${SCRIPT_DIR}"/*.proto; do
    if [ -f "$proto_file" ]; then
        echo "Processing: $(basename "$proto_file")"
        protoc \
            --proto_path="${SCRIPT_DIR}" \
            --swift_out="${OUTPUT_DIR}" \
            --swift_opt=Visibility=Public \
            --swift_opt=FileNaming=PathToUnderscores \
            "$proto_file"
    fi
done

echo "✅ Swift code generation complete!"
echo "Generated files in: ${OUTPUT_DIR}"
