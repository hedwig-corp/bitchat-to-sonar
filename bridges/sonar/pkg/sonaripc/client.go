package sonaripc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"time"
)

const protocolVersion = 1

type Config struct {
	DaemonPath    string
	MasterKeyFile string
	Relays        []string
	BlossomServer string
	MediaHosts    []string
}

type Identity struct {
	Version   int    `json:"version"`
	AccountID string `json:"account_id"`
	Npub      string `json:"npub"`
	PubkeyHex string `json:"pubkey_hex"`
}

type response struct {
	Version int             `json:"v"`
	ID      string          `json:"id"`
	OK      bool            `json:"ok"`
	Result  json.RawMessage `json:"result"`
	Error   *RPCError       `json:"error"`
}

type RPCError struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable"`
}

func (err *RPCError) Error() string {
	return fmt.Sprintf("sonar daemon %s: %s", err.Code, err.Message)
}

type Client struct {
	command *exec.Cmd
	stdin   io.WriteCloser
	stdout  *bufio.Scanner
	callMu  sync.Mutex
	stateMu sync.Mutex
	nextID  uint64
}

func InitIdentity(ctx context.Context, config Config, stateDir string) (*Identity, error) {
	command := exec.CommandContext(ctx, config.DaemonPath,
		"init",
		"--state-dir", stateDir,
		"--master-key-file", config.MasterKeyFile,
	)
	output, err := command.Output()
	if err != nil {
		return nil, fmt.Errorf("initialize Sonar identity: %w", err)
	}
	var identity Identity
	if err = json.Unmarshal(output, &identity); err != nil {
		return nil, fmt.Errorf("decode Sonar identity: %w", err)
	}
	if identity.AccountID == "" || identity.Npub == "" || identity.PubkeyHex == "" {
		return nil, errors.New("Sonar daemon returned an incomplete identity")
	}
	return &identity, nil
}

func Start(config Config, stateDir string) (*Client, error) {
	args := []string{
		"serve",
		"--state-dir", stateDir,
		"--master-key-file", config.MasterKeyFile,
	}
	for _, relay := range config.Relays {
		args = append(args, "--relay", relay)
	}
	if config.BlossomServer != "" {
		args = append(args, "--blossom-server", config.BlossomServer)
	}
	for _, host := range config.MediaHosts {
		args = append(args, "--media-host", host)
	}
	command := exec.Command(config.DaemonPath, args...)
	stdin, err := command.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdoutPipe, err := command.StdoutPipe()
	if err != nil {
		return nil, err
	}
	command.Stderr = os.Stderr
	if err = command.Start(); err != nil {
		return nil, fmt.Errorf("start Sonar daemon: %w", err)
	}
	scanner := bufio.NewScanner(stdoutPipe)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	client := &Client{command: command, stdin: stdin, stdout: scanner}
	var hello struct {
		Protocol int `json:"protocol"`
	}
	helloContext, cancelHello := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancelHello()
	if err = client.Call(helloContext, "hello", map[string]any{}, &hello); err != nil {
		_ = client.Close()
		return nil, err
	}
	if hello.Protocol != protocolVersion {
		_ = client.Close()
		return nil, fmt.Errorf("unsupported Sonar daemon protocol %d", hello.Protocol)
	}
	return client, nil
}

func (client *Client) Call(ctx context.Context, method string, params any, result any) error {
	client.callMu.Lock()
	defer client.callMu.Unlock()
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}
	client.stateMu.Lock()
	stdin, stdout := client.stdin, client.stdout
	client.nextID++
	id := strconv.FormatUint(client.nextID, 10)
	client.stateMu.Unlock()
	if stdin == nil || stdout == nil {
		return errors.New("Sonar daemon is closed")
	}
	request := map[string]any{"v": protocolVersion, "id": id, "method": method, "params": params}
	frame, err := json.Marshal(request)
	if err != nil {
		return err
	}
	frame = append(frame, '\n')
	if _, err = stdin.Write(frame); err != nil {
		return fmt.Errorf("write Sonar daemon request: %w", err)
	}
	type scanResult struct {
		frame []byte
		err   error
	}
	scanned := make(chan scanResult, 1)
	go func() {
		if !stdout.Scan() {
			if scanErr := stdout.Err(); scanErr != nil {
				scanned <- scanResult{err: scanErr}
			} else {
				scanned <- scanResult{err: errors.New("Sonar daemon stopped")}
			}
			return
		}
		frameCopy := append([]byte(nil), stdout.Bytes()...)
		scanned <- scanResult{frame: frameCopy}
	}()
	var scan scanResult
	select {
	case scan = <-scanned:
	case <-ctx.Done():
		_ = client.Close()
		scan = <-scanned
		return ctx.Err()
	}
	if scan.err != nil {
		return fmt.Errorf("read Sonar daemon response: %w", scan.err)
	}
	var response response
	if err = json.Unmarshal(scan.frame, &response); err != nil {
		return fmt.Errorf("decode Sonar daemon response: %w", err)
	}
	if response.ID != id || response.Version != protocolVersion {
		return errors.New("Sonar daemon response correlation failed")
	}
	if !response.OK {
		if response.Error == nil {
			return errors.New("Sonar daemon returned an unspecified error")
		}
		return response.Error
	}
	if result == nil {
		return nil
	}
	return json.Unmarshal(response.Result, result)
}

func (client *Client) Close() error {
	client.stateMu.Lock()
	if client.command == nil {
		client.stateMu.Unlock()
		return nil
	}
	command, stdin := client.command, client.stdin
	client.command = nil
	client.stdin = nil
	client.stdout = nil
	client.stateMu.Unlock()
	_ = stdin.Close()
	err := command.Process.Kill()
	_ = command.Wait()
	if errors.Is(err, os.ErrProcessDone) {
		return nil
	}
	return err
}

func ResolveStateDir(root, stateID string) (string, error) {
	if filepath.Base(stateID) != stateID || stateID == "." || stateID == ".." || stateID == "" {
		return "", errors.New("invalid Sonar account state ID")
	}
	root, err := filepath.Abs(root)
	if err != nil {
		return "", err
	}
	return filepath.Join(root, stateID), nil
}
