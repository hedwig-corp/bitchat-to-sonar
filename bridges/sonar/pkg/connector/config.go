package connector

import (
	_ "embed"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"time"

	"go.mau.fi/util/configupgrade"
	"maunium.net/go/mautrix/bridgev2"
)

//go:embed example-config.yaml
var exampleConfig string

type Config struct {
	DaemonPath         string   `yaml:"daemon_path"`
	StateDir           string   `yaml:"state_dir"`
	MasterKeyFile      string   `yaml:"master_key_file"`
	Relays             []string `yaml:"relays"`
	BlossomServer      string   `yaml:"blossom_server"`
	MediaDownloadHosts []string `yaml:"media_download_hosts"`
	PollIntervalMillis int      `yaml:"poll_interval_millis"`
}

func (config *Config) PollInterval() time.Duration {
	if config.PollIntervalMillis < 250 {
		return 2 * time.Second
	}
	return time.Duration(config.PollIntervalMillis) * time.Millisecond
}

func (config *Config) normalize() {
	if config.BlossomServer == "" {
		config.BlossomServer = "https://nostr.download"
	}
	if config.PollIntervalMillis == 0 {
		config.PollIntervalMillis = 2000
	}
	if len(config.MediaDownloadHosts) == 0 {
		if parsed, err := url.Parse(config.BlossomServer); err == nil && parsed.Hostname() != "" {
			config.MediaDownloadHosts = []string{parsed.Hostname()}
		}
	}
}

var _ bridgev2.ConfigValidatingNetwork = (*SonarConnector)(nil)

func (connector *SonarConnector) GetConfig() (string, any, configupgrade.Upgrader) {
	return exampleConfig, &connector.Config, nil
}

func (connector *SonarConnector) ValidateConfig() error {
	connector.Config.normalize()
	for name, value := range map[string]string{
		"daemon_path":     connector.Config.DaemonPath,
		"state_dir":       connector.Config.StateDir,
		"master_key_file": connector.Config.MasterKeyFile,
	} {
		if value == "" {
			return fmt.Errorf("%s is required", name)
		}
	}
	if info, err := os.Stat(connector.Config.DaemonPath); err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
		return fmt.Errorf("daemon_path is not an executable file")
	}
	if !filepath.IsAbs(connector.Config.StateDir) || !filepath.IsAbs(connector.Config.MasterKeyFile) {
		return fmt.Errorf("state_dir and master_key_file must be absolute paths")
	}
	if len(connector.Config.Relays) == 0 {
		return fmt.Errorf("at least one relay is required")
	}
	for _, relay := range connector.Config.Relays {
		parsed, parseErr := url.Parse(relay)
		if parseErr != nil || parsed.Scheme != "wss" || parsed.Hostname() == "" || parsed.User != nil {
			return fmt.Errorf("relays must be public wss URLs without embedded credentials")
		}
	}
	blossomURL, err := url.Parse(connector.Config.BlossomServer)
	if err != nil || blossomURL.Scheme != "https" || blossomURL.Hostname() == "" || blossomURL.User != nil || (blossomURL.EscapedPath() != "" && blossomURL.EscapedPath() != "/") || blossomURL.RawQuery != "" || blossomURL.Fragment != "" {
		return fmt.Errorf("blossom_server must be a public HTTPS base URL without credentials, query, or fragment")
	}
	for _, host := range connector.Config.MediaDownloadHosts {
		if parsed, parseErr := url.Parse("https://" + host); parseErr != nil || parsed.Hostname() != host || parsed.Port() != "" {
			return fmt.Errorf("media_download_hosts must contain hostnames without schemes or ports")
		}
	}
	return nil
}
