DUNE_BUILD = dune build
BIN_DIR = bin
DATA_DIR = data
FRONTEND_EXEC = _build/default/lib/frontend.exe
SERVER_EXEC = _build/default/lib/server.exe
LOG_FILE = raft.log
SRC_FILES = lib/*.ml

# Default target
all: $(BIN_DIR)/frontend $(BIN_DIR)/server

# Target to build with Dune for frontend
$(FRONTEND_EXEC): $(SRC_FILES)
	$(DUNE_BUILD)

# Target to build with Dune for server
$(SERVER_EXEC): $(SRC_FILES)
	$(DUNE_BUILD)

# Ensure bin directory exists
$(BIN_DIR):
	mkdir -p $(BIN_DIR)

# Ensure data directory exists
$(DATA_DIR):
	mkdir -p $(DATA_DIR)

# Copy executable to bin for server
$(BIN_DIR)/server: $(SERVER_EXEC) | $(BIN_DIR)
	cp $(SERVER_EXEC) $(BIN_DIR)/server

# Copy executable to bin for frontend
$(BIN_DIR)/frontend: $(FRONTEND_EXEC) | $(BIN_DIR)
	cp $(FRONTEND_EXEC) $(BIN_DIR)/frontend

# Run frontend and server, redirect output to a log file
up: $(BIN_DIR)/frontend $(BIN_DIR)/server $(DATA_DIR)
	rm -f $(DATA_DIR)/$(LOG_FILE)
	$(BIN_DIR)/frontend >> $(DATA_DIR)/$(LOG_FILE) 2>&1 &

# Rule to kill the frontend and server processes
down:
	@echo "Killing frontend process..."
	@ps aux | grep 'bin/frontend' | grep -v 'grep' | awk '{print $$2}' | xargs -r kill
	@echo "Killing server processes..."
	@ps aux | grep 'raftserver' | grep -v 'grep' | awk '{print $$2}' | xargs -r kill

# Clean build artifacts and bin directory
clean: down
	rm -rf $(BIN_DIR)/*
	rm -rf $(DATA_DIR)
	dune clean
