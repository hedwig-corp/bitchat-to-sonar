package connector

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/bridgev2/simplevent"
	"maunium.net/go/mautrix/event"
)

type remoteMedia struct {
	URL        string  `json:"url"`
	MimeType   string  `json:"mime_type"`
	Filename   string  `json:"filename"`
	Width      *uint32 `json:"width"`
	Height     *uint32 `json:"height"`
	DurationMS *uint64 `json:"duration_ms"`
}

type remoteMessage struct {
	ID            string        `json:"id"`
	GroupID       string        `json:"group_id"`
	Sender        string        `json:"sender"`
	Content       string        `json:"content"`
	CreatedAtSecs uint64        `json:"created_at_secs"`
	Mine          bool          `json:"mine"`
	Media         []remoteMedia `json:"media"`
}

type replayEvent struct {
	Sequence uint64        `json:"seq"`
	PeerHex  string        `json:"peer_hex"`
	Message  remoteMessage `json:"message"`
}

func (client *SonarClient) pollEvents(ctx context.Context) error {
	metadata := client.metadata()
	if client.queuedRemoteID != "" {
		stored, err := client.UserLogin.Bridge.DB.Message.GetFirstPartByID(
			ctx,
			client.UserLogin.ID,
			client.queuedRemoteID,
		)
		if err != nil {
			return fmt.Errorf("check Sonar message mapping: %w", err)
		}
		if stored == nil {
			return nil
		}
		if err = client.advanceCursor(ctx, client.queuedRemoteSeq); err != nil {
			return err
		}
		client.queuedRemoteID = ""
		client.queuedRemoteSeq = 0
	}
	var replay struct {
		Events []replayEvent `json:"events"`
	}
	if err := client.call(ctx, "events", map[string]any{"after": metadata.EventCursor, "limit": 50}, &replay); err != nil {
		return err
	}
	for _, item := range replay.Events {
		if item.Message.Mine {
			if err := client.advanceCursor(ctx, item.Sequence); err != nil {
				return err
			}
			continue
		}
		messageID := networkid.MessageID(item.Message.ID)
		stored, err := client.UserLogin.Bridge.DB.Message.GetFirstPartByID(ctx, client.UserLogin.ID, messageID)
		if err != nil {
			return fmt.Errorf("check existing Sonar message mapping: %w", err)
		}
		if stored != nil {
			if err = client.advanceCursor(ctx, item.Sequence); err != nil {
				return err
			}
			continue
		}
		queued := client.UserLogin.Bridge.QueueRemoteEvent(client.UserLogin, &simplevent.Message[remoteMessage]{
			EventMeta: simplevent.EventMeta{
				Type:         bridgev2.RemoteEventMessage,
				PortalKey:    client.portalKey(item.PeerHex),
				CreatePortal: true,
				Sender:       bridgev2.EventSender{Sender: networkid.UserID(item.PeerHex)},
				Timestamp:    time.Unix(int64(item.Message.CreatedAtSecs), 0),
			},
			Data:               item.Message,
			ID:                 messageID,
			ConvertMessageFunc: client.convertMessage,
		})
		if !queued.Success {
			if queued.Error != nil {
				return fmt.Errorf("queue Sonar remote event: %w", queued.Error)
			}
			return fmt.Errorf("queue Sonar remote event failed")
		}
		client.queuedRemoteID = messageID
		client.queuedRemoteSeq = item.Sequence
		break
	}
	return nil
}

func (client *SonarClient) advanceCursor(ctx context.Context, sequence uint64) error {
	var acknowledged map[string]any
	if err := client.call(
		context.WithoutCancel(ctx),
		"ack_events",
		map[string]any{"through": sequence},
		&acknowledged,
	); err != nil {
		return fmt.Errorf("acknowledge Sonar replay cursor: %w", err)
	}
	previous := client.metadata().EventCursor
	client.metadata().EventCursor = sequence
	if err := client.UserLogin.Save(context.WithoutCancel(ctx)); err != nil {
		client.metadata().EventCursor = previous
		return fmt.Errorf("save Sonar replay cursor: %w", err)
	}
	return nil
}

func (client *SonarClient) convertMessage(
	ctx context.Context,
	portal *bridgev2.Portal,
	intent bridgev2.MatrixAPI,
	message remoteMessage,
) (*bridgev2.ConvertedMessage, error) {
	if len(message.Media) == 0 {
		return &bridgev2.ConvertedMessage{Parts: []*bridgev2.ConvertedMessagePart{{
			Type:    event.EventMessage,
			Content: &event.MessageEventContent{MsgType: event.MsgText, Body: message.Content},
		}}}, nil
	}

	parts := make([]*bridgev2.ConvertedMessagePart, 0, len(message.Media))
	for index, media := range message.Media {
		var fetched struct {
			Path string `json:"path"`
			Size int64  `json:"size"`
		}
		if err := client.call(ctx, "fetch_media", map[string]any{
			"group_id": message.GroupID,
			"url":      media.URL,
		}, &fetched); err != nil {
			return nil, fmt.Errorf("fetch Sonar media: %w", err)
		}
		url, encryptedFile, err := intent.UploadMediaStream(ctx, portal.MXID, fetched.Size, true, func(destination io.Writer) (*bridgev2.FileStreamResult, error) {
			source, openErr := os.Open(fetched.Path)
			if openErr != nil {
				return nil, openErr
			}
			defer source.Close()
			if _, copyErr := io.Copy(destination, source); copyErr != nil {
				return nil, copyErr
			}
			return &bridgev2.FileStreamResult{FileName: media.Filename, MimeType: media.MimeType}, nil
		})
		var ignored map[string]any
		_ = client.call(context.WithoutCancel(ctx), "release_media", map[string]any{"path": fetched.Path}, &ignored)
		if err != nil {
			return nil, fmt.Errorf("upload Sonar media to Matrix: %w", err)
		}
		content := &event.MessageEventContent{
			MsgType:  matrixMessageType(media.MimeType),
			Body:     media.Filename,
			FileName: media.Filename,
			URL:      url,
			File:     encryptedFile,
			Info: &event.FileInfo{
				MimeType: media.MimeType,
				Size:     int(fetched.Size),
			},
		}
		if media.Width != nil {
			content.Info.Width = int(*media.Width)
		}
		if media.Height != nil {
			content.Info.Height = int(*media.Height)
		}
		if media.DurationMS != nil {
			content.Info.Duration = boundedUint64ToInt(*media.DurationMS)
		}
		if index == 0 && message.Content != "" {
			content.Body = message.Content
		}
		parts = append(parts, &bridgev2.ConvertedMessagePart{
			ID:      networkid.PartID(strconv.Itoa(index)),
			Type:    event.EventMessage,
			Content: content,
		})
	}
	return &bridgev2.ConvertedMessage{Parts: parts}, nil
}

func (client *SonarClient) HandleMatrixMessage(ctx context.Context, message *bridgev2.MatrixMessage) (*bridgev2.MatrixMessageResponse, error) {
	transactionKey := string(message.InputTransactionID)
	if transactionKey == "" && message.Event != nil {
		transactionKey = string(message.Event.ID)
	}
	if transactionKey == "" {
		return nil, fmt.Errorf("Matrix event has no stable transaction ID")
	}
	params := map[string]any{
		"transaction_key": transactionKey,
		"peer":            string(message.Portal.ID),
	}
	var result struct {
		MessageID     string `json:"message_id"`
		Queued        bool   `json:"queued"`
		Indeterminate bool   `json:"indeterminate"`
		Status        string `json:"status"`
	}

	if message.Content.MsgType.IsMedia() {
		if message.Content.MSC3245Voice != nil {
			return nil, fmt.Errorf("Sonar voice-note classification is not supported yet; send as an audio file")
		}
		err := client.UserLogin.Bridge.Bot.DownloadMediaToFile(ctx, message.Content.URL, message.Content.File, false, func(file *os.File) error {
			params["source_path"] = file.Name()
			params["filename"] = matrixFilename(message.Content)
			params["mime"] = matrixMime(message.Content)
			params["caption"] = matrixCaption(message.Content)
			return client.call(ctx, "send_media", params, &result)
		})
		if err != nil {
			return nil, err
		}
	} else {
		params["text"] = message.Content.Body
		if err := client.call(ctx, "send_text", params, &result); err != nil {
			return nil, err
		}
	}
	if result.MessageID == "" {
		return nil, fmt.Errorf("Sonar daemon returned no message ID")
	}
	if result.Queued {
		failure := fmt.Errorf("Sonar send is %s", result.Status)
		status := event.MessageStatusPending
		statusMessage := "Sonar has not sent this message yet; retrying the same Matrix event is safe"
		if result.Indeterminate {
			status = event.MessageStatusFail
			statusMessage = "Sonar may have committed this message locally; it was not replayed to avoid a duplicate"
		}
		return nil, bridgev2.MessageStatus{
			Status:        status,
			InternalError: failure,
			Message:       statusMessage,
			IsCertain:     !result.Indeterminate,
		}
	}
	return &bridgev2.MatrixMessageResponse{DB: &database.Message{
		ID:       networkid.MessageID(result.MessageID),
		SenderID: client.selfUserID(),
	}}, nil
}

func boundedUint64ToInt(value uint64) int {
	maxInt := uint64(^uint(0) >> 1)
	if value > maxInt {
		return int(maxInt)
	}
	return int(value)
}

func matrixMessageType(mime string) event.MessageType {
	switch {
	case strings.HasPrefix(mime, "image/"):
		return event.MsgImage
	case strings.HasPrefix(mime, "video/"):
		return event.MsgVideo
	case strings.HasPrefix(mime, "audio/"):
		return event.MsgAudio
	default:
		return event.MsgFile
	}
}

func matrixFilename(content *event.MessageEventContent) string {
	name := content.FileName
	if name == "" {
		name = content.Body
	}
	name = filepath.Base(strings.ReplaceAll(name, "\\", "/"))
	if name == "." || name == "/" || name == "" {
		return "attachment"
	}
	return name
}

func matrixMime(content *event.MessageEventContent) string {
	if mime := content.GetInfo().MimeType; strings.Contains(mime, "/") {
		return mime
	}
	return "application/octet-stream"
}

func matrixCaption(content *event.MessageEventContent) string {
	if content.FileName != "" && content.Body != content.FileName {
		return content.Body
	}
	return ""
}
