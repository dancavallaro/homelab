package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/aws/aws-sdk-go-v2/service/sts/types"
	"github.com/dancavallaro/telemetry/pkg/awso"
	"log"
	"os"
	"path"
	"strings"
	"time"
)

const (
	required              = "<REQUIRED>"
	stalenessThreshold    = 20 * time.Minute
	maxAssumeRoleAttempts = 3
)

var (
	configDir = flag.String("configDir", required, "Directory to read config files from")
	region    = flag.String("region", "us-east-1", "AWS region to use")
)

type config struct {
	User        string `json:"user"`
	RoleArn     string `json:"role_arn"`
	SessionName string `json:"session_name"`
}

type stsClientProvider interface {
	Client() *sts.Client
}

func assumeRole(client stsClientProvider, cfg config) (*types.Credentials, error) {
	log.Printf("Refreshing credentials for user %s\n", cfg.User)

	var output *sts.AssumeRoleOutput
	var err error
	for attempt := 0; attempt < maxAssumeRoleAttempts; attempt++ {
		output, err = client.Client().AssumeRole(context.Background(), &sts.AssumeRoleInput{
			RoleArn:         aws.String(cfg.RoleArn),
			RoleSessionName: aws.String(cfg.SessionName),
		})
		// If the call was successful, or failed with an error other than ClientInvalidated, we're done.
		if err == nil || !errors.Is(err, awso.ClientInvalidated) {
			break
		}
		// If the error was ClientInvalidated, and we have at least one attempt left,
		// we'll sleep for a delay and then try again.
		if attempt < maxAssumeRoleAttempts-1 {
			log.Println("IAM creds are expired, will try again after delay")
			time.Sleep(5 * time.Second)
		}
	}
	return output.Credentials, err
}

func refresh(client stsClientProvider, cfg config) error {
	credsPath := fmt.Sprintf("/home/%s/.aws/credentials", cfg.User)

	credsFile, err := os.Open(credsPath)
	if err != nil {
		return err
	}
	credsInfo, err := credsFile.Stat()
	if err != nil {
		return err
	}

	credsStaleness := time.Now().Sub(credsInfo.ModTime())
	if credsStaleness < stalenessThreshold && credsInfo.Size() > 0 {
		log.Printf("Creds for user %s are only %d minutes old\n", cfg.User, int(credsStaleness.Minutes()))
		return nil
	}

	creds, err := assumeRole(client, cfg)
	if err != nil {
		return err
	}

	var sb strings.Builder
	sb.WriteString("[default]\n")
	sb.WriteString(fmt.Sprintf("aws_access_key_id = %s\n", *creds.AccessKeyId))
	sb.WriteString(fmt.Sprintf("aws_secret_access_key = %s\n", *creds.SecretAccessKey))
	sb.WriteString(fmt.Sprintf("aws_session_token = %s\n", *creds.SessionToken))

	err = os.WriteFile(credsPath, []byte(sb.String()), 0600)
	if err == nil {
		log.Printf("Wrote credentials for user %s to %s\n", cfg.User, credsPath)
	}
	return err
}

func main() {
	log.SetFlags(log.Ldate | log.Ltime)
	log.SetPrefix("[credential-refresher] ")

	flag.Parse()

	if *configDir == required {
		panic("must specify configDir!")
	}

	client := awso.NewClientProvider(func(cfg aws.Config) *sts.Client {
		cfg.Region = *region
		log.Println("Creating new STS client")
		return sts.NewFromConfig(cfg)
	})

	for {
		log.Println("Starting credential-refresher run")

		files, err := os.ReadDir(*configDir)
		if err != nil {
			panic(err)
		}

		for _, e := range files {
			filePath := path.Join(*configDir, e.Name())
			content, err := os.ReadFile(filePath)
			if err != nil {
				panic(err)
			}
			var cfg config
			err = json.Unmarshal(content, &cfg)
			if err != nil {
				panic(err)
			}
			err = refresh(&client, cfg)
			if err != nil {
				panic(err)
			}
		}

		log.Println("Done; sleeping till next run")
		time.Sleep(1 * time.Minute)
	}
}
