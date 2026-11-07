TARGET = AntigravitySnap
SRC = main.swift

all: $(TARGET)

$(TARGET): $(SRC)
	swiftc -O $(SRC) -o $(TARGET)

clean:
	rm -f $(TARGET)

install: $(TARGET)
	mkdir -p ~/.local/bin
	cp $(TARGET) ~/.local/bin/

.PHONY: all clean install
