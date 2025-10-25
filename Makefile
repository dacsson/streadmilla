.PHONY: all clean

# TODO: zig fetch --save git+https://github.com/ziglang/translate-c

BUILD_DIR := $(CURDIR)/build

BIN_NAME := $(notdir $(basename $(FILE)))

C_FLAGS := -fsanitize=undefined -I . -L . -l:zig-out/lib/libstreadmilla.a

ZIG_FLAGS := $(UNDEF)

# FLAGS
ifeq ($(DEBUG),1)
	ZIG_FLAGS += -Ddebug=true
else
	ZIG_FLAGS += --release=safe
endif

ifeq ($(GC_STATS),1)
	ZIG_FLAGS += -Dgc-stats=true
endif

ifeq ($(RT_STATS),1)
	ZIG_FLAGS += -Drt-stats=true
endif


all: $(BIN_NAME)

# Build the Zig library
zig-out/lib/libstreadmilla.a:
	@echo "📚 Building Zig library"
	zig build $(ZIG_FLAGS)

# Compile Stella file
%.stella: zig-out/lib/libstreadmilla.a
	@echo "🏗️  Building Stella file: $(FILE)"
	@mkdir -p $(BUILD_DIR)
	docker run -i fizruk/stella compile < $(FILE) > $(BUILD_DIR)/$(BIN_NAME).c

# Build the Zig library first
$(BIN_NAME): %.stella
	@echo "🛠  Building C executable: $(BUILD_DIR)/$@"
	@mkdir -p $(BUILD_DIR)
	gcc -std=c11 $(BUILD_DIR)/$(BIN_NAME).c $(C_FLAGS) -o $(BUILD_DIR)/$(BIN_NAME)

# Build and run all *.stella files in `test-stella`
test:
	@echo "🧪 Running tests..."
	@for file in $(wildcard test-stella/*.stella); do \
		echo "🧪 Running test: $$file"; \
		make FILE=$$file; \
		echo 10 | ./build/$$(basename $$file .stella); \
		make clean; \
	done

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
