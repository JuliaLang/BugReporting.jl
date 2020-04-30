package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"os"
	"time"

	"github.com/google/go-github/github"

	"golang.org/x/oauth2"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/apigatewaymanagementapi"
	"github.com/aws/aws-sdk-go/service/sts"
)

var debugLogger = log.New(os.Stderr, "DEBUG ", log.Llongfile)
var errorLogger = log.New(os.Stderr, "ERROR ", log.Llongfile)

type uaSetterTransport struct{}

func (t *uaSetterTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	// modify req here
	req.Header.Set("User-Agent", "JuliaRR-Lambda/0.1")
	//req.Header.Set("Accept", "application/vnd.github.machine-man-preview+json")

	// Dump request headers
	req_dump, _ := httputil.DumpRequest(req, false)
	debugLogger.Printf("REQ:\n%s", req_dump)

	// Call default rounttrip
	response, err := http.DefaultTransport.RoundTrip(req)

	res_dump, _ := httputil.DumpResponse(response, true)
	debugLogger.Printf("RES:\n%s", res_dump)

	// return result of default roundtrip
	return response, err
}

func convertPolicyARNs(policyARNs []string) []*sts.PolicyDescriptorType {
	size := len(policyARNs)
	retval := make([]*sts.PolicyDescriptorType, size, size)
	for i, arn := range policyARNs {
		retval[i] = &sts.PolicyDescriptorType{
			Arn: aws.String(arn),
		}
	}
	return retval
}

type UserCredentialsResponse struct {
	UPLOAD_PATH           string
	AWS_ACCESS_KEY_ID     string
	AWS_SECRET_ACCESS_KEY string
	AWS_SESSION_TOKEN     string
}

var ws_mgmt_endpoint = "https://53ly7yebjg.execute-api.us-east-1.amazonaws.com/test"

func vendor(req events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	code := req.QueryStringParameters["code"]
	state := req.QueryStringParameters["state"]
	if code == "" || state == "" {
		return clientError(400)
	}
	debugLogger.Println(fmt.Sprintf("Code is %s", code))
	hc := &http.Client{Transport: &uaSetterTransport{}}
	ctx := context.WithValue(context.Background(), oauth2.HTTPClient, hc)
	var endpoint = oauth2.Endpoint{
		AuthURL:   "https://github.com/login/oauth/authorize",
		TokenURL:  "https://github.com/login/oauth/access_token",
		AuthStyle: oauth2.AuthStyleInParams,
	}
	conf := &oauth2.Config{
		ClientID:     "Iv1.c29a629771fe63c4",
		ClientSecret: os.Getenv("CLIENT_SECRET"),
		Scopes:       []string{""},
		Endpoint:     endpoint}
	token, err := conf.Exchange(ctx, code)
	if err != nil {
		return serverError(err)
	}
	tc := oauth2.NewClient(ctx, conf.TokenSource(ctx, token))
	client := github.NewClient(tc)

	user, _, err := client.Users.Get(ctx, "")

	/*
		emails, _, err := client.Users.ListEmails(ctx, nil)
		if err != nil {
			return serverError(err)
		}
	*/

	user_name := user.GetName()

	// Get an AWS token for the user
	os.Setenv("AWS_ACCESS_KEY_ID", os.Getenv("STS_AWS_ACCESS_KEY_ID"))
	os.Setenv("AWS_SECRET_ACCESS_KEY", os.Getenv("STS_AWS_SECRET_ACCESS_KEY"))
	os.Unsetenv("AWS_SESSION_TOKEN")

	currentTime := time.Now()
	fname := fmt.Sprintf("reports/%s-%s.tar.gz", currentTime.Format("2006-01-02T15-04-05"), user.GetLogin())

	awsSession := session.New()
	svc := sts.New(awsSession)
	tokenInput := &sts.GetFederationTokenInput{
		DurationSeconds: aws.Int64(60*60),
	}
	tokenInput.Name = aws.String(user.GetLogin())
	PolicyArns := []string{"arn:aws:iam::873569884612:policy/julialang-dumps-upload"}
	tokenInput.PolicyArns = convertPolicyARNs(PolicyArns)
	policy := fmt.Sprintf(`{
		"Version": "2012-10-17",
		"Statement": [
			{
				"Effect": "Allow",
				"Action": "s3:PutObject",
				"Resource": "arn:aws:s3:::julialang-dumps/%s"
			}
		]
	}`, fname)
	tokenInput.Policy = &policy

	tokenOut, err := svc.GetFederationToken(tokenInput)
	if err != nil {
		return serverError(err)
	}

	// Send to the user's WebSocket session
	wsMgmt := apigatewaymanagementapi.New(awsSession, aws.NewConfig().WithEndpoint(ws_mgmt_endpoint))

	awsCreds := tokenOut.Credentials
	response := UserCredentialsResponse{
		UPLOAD_PATH:           fname,
		AWS_ACCESS_KEY_ID:     *awsCreds.AccessKeyId,
		AWS_SECRET_ACCESS_KEY: *awsCreds.SecretAccessKey,
		AWS_SESSION_TOKEN:     *awsCreds.SessionToken,
	}

	responseData, err := json.Marshal(response)
	if err != nil {
		return serverError(err)
	}

	debugLogger.Println(fmt.Sprintf("State is %s", state))
	_, err = wsMgmt.PostToConnection(&apigatewaymanagementapi.PostToConnectionInput{
		ConnectionId: aws.String(state),
		Data:         responseData,
	})
	if err != nil {
		return serverError(err)
	}

	body := fmt.Sprintf("Hello %s, your upload has been authorized and will begin automatically.", user_name)

	return events.APIGatewayProxyResponse{
		StatusCode: http.StatusOK,
		Body:       body,
	}, nil
}

// Add a helper for handling errors. This logs any error to os.Stderr
// and returns a 500 Internal Server Error response that the AWS API
// Gateway understands.
func serverError(err error) (events.APIGatewayProxyResponse, error) {
	errorLogger.Println(err.Error())

	return events.APIGatewayProxyResponse{
		StatusCode: http.StatusInternalServerError,
		Body:       http.StatusText(http.StatusInternalServerError),
	}, nil
}

// Similarly add a helper for send responses relating to client errors.
func clientError(status int) (events.APIGatewayProxyResponse, error) {
	return events.APIGatewayProxyResponse{
		StatusCode: status,
		Body:       http.StatusText(status),
	}, nil
}

func main() {
	lambda.Start(vendor)
}
