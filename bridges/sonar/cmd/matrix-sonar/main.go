package main

import (
	"maunium.net/go/mautrix/bridgev2/matrix/mxmain"

	"github.com/hedwig-corp/bitchat-to-sonar/bridges/sonar/pkg/connector"
)

var (
	Tag       = "unknown"
	Commit    = "unknown"
	BuildTime = "unknown"
)

func main() {
	main := mxmain.BridgeMain{
		Name:        "matrix-sonar",
		Description: "A local-first Matrix/Beeper bridge for Sonar",
		URL:         "https://github.com/hedwig-corp/bitchat-to-sonar",
		Version:     "0.1.0",
		Connector:   &connector.SonarConnector{},
	}
	main.InitVersion(Tag, Commit, BuildTime)
	main.Run()
}
