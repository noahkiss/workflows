package selftest

import "testing"

func add(a, b int) int { return a + b }

func TestAdd(t *testing.T) {
	if add(2, 3) != 5 {
		t.Fatal("add(2, 3) != 5")
	}
}
