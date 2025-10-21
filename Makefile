.PHONY: all clean

BUILD_DIR := $(CURDIR)/build

BIN_NAME := $(notdir $(basename $(FILE)))

all: $(BIN_NAME)

# Build the Zig library
zig-out/lib/libstreadmilla.a:
	@echo "📚 Building Zig library"
	@zig build

# Compile Stella file
%.stella: zig-out/lib/libstreadmilla.a
	@echo "🏗️  Building Stella file: $(FILE)"
	@mkdir -p $(BUILD_DIR)
	@docker run -i fizruk/stella compile < $(FILE) > $(BUILD_DIR)/$(BIN_NAME).c

# Build the Zig library first
$(BIN_NAME): %.stella
	@echo "🛠  Building C executable: $(BUILD_DIR)/$@"
	@mkdir -p $(BUILD_DIR)
	@gcc -std=c11 $(BUILD_DIR)/$(BIN_NAME).c -fsanitize=undefined -I . -L . -l:zig-out/lib/libstreadmilla.a -o $(BUILD_DIR)/$(BIN_NAME)

# Clean target
clean:
	@echo "🧹 Cleaning up..."
	@rm -rf $(BUILD_DIR) zig-out/lib/libstreadmilla.a

# Help target
help:
	@echo "Usage: make FILE=<filename.c>"
	@echo "  FILE=<filename.c>  The C source file to compile"
	@echo "  make clean         Remove generated library"
	@echo "  make help          Show this help"

# Default help if no target specified
.PHONY: help
