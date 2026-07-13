package connector

import (
	"testing"

	"maunium.net/go/mautrix/event"
)

func TestMatrixFilenameCannotEscapeSpool(t *testing.T) {
	content := &event.MessageEventContent{Body: "caption", FileName: `..\\private/secret.txt`}
	if got := matrixFilename(content); got != "secret.txt" {
		t.Fatalf("unexpected sanitized name %q", got)
	}
}

func TestCaptionIsNotDuplicatedFromFilename(t *testing.T) {
	if got := matrixCaption(&event.MessageEventContent{Body: "a.jpg", FileName: "a.jpg"}); got != "" {
		t.Fatalf("expected empty caption, got %q", got)
	}
	if got := matrixCaption(&event.MessageEventContent{Body: "hello", FileName: "a.jpg"}); got != "hello" {
		t.Fatalf("expected caption, got %q", got)
	}
}

func TestMediaKinds(t *testing.T) {
	cases := map[string]event.MessageType{
		"image/jpeg":      event.MsgImage,
		"video/mp4":       event.MsgVideo,
		"audio/ogg":       event.MsgAudio,
		"application/pdf": event.MsgFile,
	}
	for mime, expected := range cases {
		if got := matrixMessageType(mime); got != expected {
			t.Fatalf("%s: expected %s, got %s", mime, expected, got)
		}
	}
}

func TestMatrixMimeDefaultsMissingMetadata(t *testing.T) {
	if got := matrixMime(&event.MessageEventContent{}); got != "application/octet-stream" {
		t.Fatalf("unexpected MIME fallback %q", got)
	}
	if got := matrixMime(&event.MessageEventContent{Info: &event.FileInfo{MimeType: "image/png"}}); got != "image/png" {
		t.Fatalf("unexpected preserved MIME %q", got)
	}
}

func TestMediaDurationConversionIsBounded(t *testing.T) {
	if got := boundedUint64ToInt(1234); got != 1234 {
		t.Fatalf("unexpected duration %d", got)
	}
	if got := boundedUint64ToInt(^uint64(0)); got < 0 {
		t.Fatalf("overflowed duration %d", got)
	}
}

func TestVoiceNotesAreNotAdvertised(t *testing.T) {
	features := (&SonarClient{}).GetCapabilities(nil, nil)
	if _, ok := features.File[event.CapMsgVoice]; ok {
		t.Fatal("voice notes must remain disabled until the shared wire model can classify them")
	}
}
