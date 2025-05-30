package publishers

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io/ioutil"
	"reflect"
	"sync"

	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/messaging/azeventhubs"
	"github.com/wso2/apk/gateway/enforcer/internal/analytics/dto"
	"github.com/wso2/apk/gateway/enforcer/internal/config"
	"github.com/wso2/apk/gateway/enforcer/internal/util"
)

// Choreo represents the ELK publisher
type Choreo struct {
	cfg            *config.Server
	hub            *azeventhubs.ProducerClient
	hashedToken    string
	eventDataBatch *azeventhubs.EventDataBatch
	mu             sync.Mutex
}

type tokenResponse struct {
	Token string `json:"token"`
}

// CustomCredential is your custom implementation of the TokenCredential interface.
type CustomCredential struct {
	authURL string
	token   string
	cfg     *config.Server
}

// GetToken implements the azcore.TokenCredential interface.
func (c *CustomCredential) GetToken(ctx context.Context, opts policy.TokenRequestOptions) (azcore.AccessToken, error) {
	// Implement your custom token retrieval logic here.
	// For example, you might retrieve a token from a custom identity provider.

	// This is a placeholder implementation.
	tlsConfig := &tls.Config{
		InsecureSkipVerify: true, // WARNING: This disables certificate verification
	}
	headers := map[string]string{
		"Authorization": "Bearer " + c.token,
	}
	response, err := util.MakeGETRequest(fmt.Sprintf("%s/%s", c.authURL, "token"), tlsConfig, headers)
	if err != nil {
		return azcore.AccessToken{}, err
	}
	var result tokenResponse
	body, _ := ioutil.ReadAll(response.Body)
	if err := json.Unmarshal(body, &result); err != nil {
		return azcore.AccessToken{}, err
	}
	token := result.Token
	expiresOn := time.Now().Add(1 * time.Hour) // Token validity duration

	return azcore.AccessToken{
		Token:     token,
		ExpiresOn: expiresOn,
	}, nil
}

func getResourceURI(sasToken string) string {
	sasAttributes := strings.Split(sasToken, "&")
	resource := strings.Split(sasAttributes[0], "=")
	resourceURI := ""
	if decodedResourceURI, err := url.QueryUnescape(resource[1]); err == nil {
		resourceURI = decodedResourceURI
	}
	return strings.Replace(resourceURI, "sb://", "", 1)
}

func getNamespace(resourceURI string) string {
	ns := strings.Split(resourceURI, "/")[0]
	return ns
	// if strings.Contains(ns, ".") {
	// 	return strings.Split(ns, ".")[0]
	// }
	// return ns
}

func getEventHubName(resourceURI string) string {
	parts := strings.SplitN(resourceURI, "/", 2)
	if len(parts) > 1 {
		return parts[1]
	}
	return ""
}

// NewChoreo creates a new ELK publisher
func NewChoreo(cfg *config.Server, authURL, token string) *Choreo {
	ctp := &CustomCredential{
		authURL: authURL,
		token:   token,
		cfg:     cfg,
	}
	tokenFromChoreo, err := ctp.GetToken(context.TODO(), policy.TokenRequestOptions{})

	if err != nil {
		cfg.Logger.Error(err, "Error while getting token from Choreo. Retrying in 5 seconds")
		// Retry after 5 seconds
		time.Sleep(5 * time.Second)
		return NewChoreo(cfg, authURL, token)
	}
	resourceURI := getResourceURI(tokenFromChoreo.Token)
	ns := getNamespace(resourceURI)
	eventHubName := getEventHubName(resourceURI)

	// cfg.Logger.Info(fmt.Sprintf("Resource URI: %s", resourceURI))
	// cfg.Logger.Info(fmt.Sprintf("Namespace: %s", ns))
	// cfg.Logger.Info(fmt.Sprintf("Event Hub Name: %s", eventHubName))
	// cred := azcore.NewSASCredential(tokenFromChoreo)
	hub, err := azeventhubs.NewProducerClient(ns, eventHubName, ctp, nil)
	// hub, err := eventhub.NewHub(ns, eventHubName, ctp)
	if err != nil {
		cfg.Logger.Error(err, "Error while creating event hub")
		return nil
	}
	cfg.Logger.Sugar().Debug(fmt.Sprintf("Hashed token: %s", util.ComputeSHA256Hash(token)))
	choreo := &Choreo{
		cfg:         cfg,
		hub:         hub,
		hashedToken: util.ComputeSHA256Hash(token),
		mu:          sync.Mutex{},
	}
	go func() {
		for {
			time.Sleep(time.Duration(cfg.EventhubPublishInterval) * time.Second)
			choreo.mu.Lock()
			if choreo.eventDataBatch != nil && choreo.eventDataBatch.NumBytes() > 0 {
				err = hub.SendEventDataBatch(context.TODO(), choreo.eventDataBatch, nil)
				if err != nil {
					cfg.Logger.Error(err, "Error while sending batch")
				} else {
					cfg.Logger.Info("Batch of events sent to Choreo successfully")
					newBatchOptions := &azeventhubs.EventDataBatchOptions{}
					batch, err := hub.NewEventDataBatch(context.TODO(), newBatchOptions)
					if err != nil {
						cfg.Logger.Error(err, "Error while creating new batch")
						return
					}
					choreo.eventDataBatch = batch
				}
			}
			choreo.mu.Unlock()
		}
	}()
	return choreo
}

// Publish publishes the event to ELK
func (e *Choreo) Publish(event *dto.Event) {
	e.cfg.Logger.Sugar().Debug(fmt.Sprintf("Publishing event to Choreo: %+v", event))
	defer func() {
		if r := recover(); r != nil {
			e.cfg.Logger.Error(nil, fmt.Sprintf("Recovered from panic: %v", r))
		}
	}()
	// Implement the ELK publish logic
	if e.isFault(event) {
		e.publishFault(event)
	} else {
		e.publishEvent(event)
	}
}

func setDefaultUnknown(v interface{}) {
	val := reflect.ValueOf(v).Elem()
	for i := 0; i < val.NumField(); i++ {
		field := val.Field(i)
		if field.Kind() == reflect.String && field.String() == "" {
			field.SetString("unknown")
		}
	}
}

func (e *Choreo) publishEvent(event *dto.Event) {
	choreoResponseEvent := &dto.DefaultResponseEvent{
		APIName:                  event.API.APIName,
		APIID:                    event.API.APIID,
		APIType:                  event.API.APIType,
		APIVersion:               event.API.APIVersion,
		OrganizationID:           event.API.OrganizationID,
		EnvironmentID:            event.API.EnvironmentID,
		APICreatorTenantDomain:   event.API.APICreatorTenantDomain,
		APIContext:               event.API.APIContext,
		APIMethod:                event.Operation.APIMethod,
		APIResourceTemplate:      event.Operation.APIResourceTemplate,
		TargetResponseCode:       event.Target.TargetResponseCode,
		ProxyResponseCode:        event.ProxyResponseCode,
		ResponseCacheHit:         event.Target.ResponseCacheHit,
		Destination:              event.Target.Destination,
		CorrelationID:            event.MetaInfo.CorrelationID,
		RegionID:                 event.MetaInfo.RegionID,
		GatewayType:              event.MetaInfo.GatewayType,
		ResponseLatency:          event.Latencies.ResponseLatency,
		BackendLatency:           event.Latencies.BackendLatency,
		RequestMediationLatency:  event.Latencies.RequestMediationLatency,
		ResponseMediationLatency: event.Latencies.ResponseMediationLatency,
		KeyType:                  event.Application.KeyType,
		ApplicationID:            event.Application.ApplicationID,
		ApplicationName:          event.Application.ApplicationName,
		ApplicationOwner:         event.Application.ApplicationOwner,
		UserAgentHeader:          event.UserAgentHeader,
		UserName:                 event.UserName,
		UserIP:                   event.UserIP,
		RequestTimestamp:         event.RequestTimestamp.Format(timeFormat),
		EventType:                "response",
		Properties:               event.Properties,
	}
	choreoResponseEvent.Platform = "Other"
	choreoResponseEvent.EnvironmentID = "Default"
	choreoResponseEvent.GatewayType = "Onprem"
	choreoResponseEvent.KeyType = "PRODUCTION"
	if choreoResponseEvent.ApplicationOwner == "" {
		choreoResponseEvent.ApplicationOwner = "anonymous"
	}
	setDefaultUnknown(choreoResponseEvent)

	jsonString, err := util.ToJSONString(choreoResponseEvent)
	if err != nil {
		e.cfg.Logger.Error(err, "Error while converting to JSON string")
		return
	}
	e.cfg.Logger.Sugar().Debug(fmt.Sprintf("JSON string: %s", jsonString))
	eventData := &azeventhubs.EventData{
		Body: []byte(jsonString),
	}
	if eventData.Properties == nil {
		eventData.Properties = make(map[string]interface{})
	}
	eventData.Properties["token-hash"] = e.hashedToken
	eventData.CorrelationID = event.MetaInfo.CorrelationID
	eventData.MessageID = &event.MetaInfo.CorrelationID
	e.addEvent(eventData)
	e.cfg.Logger.Info("Success event added to batch successfully")

}

func (e *Choreo) publishFault(event *dto.Event) {
	choreoResponseEvent := &dto.DefaultFaultEvent{
		APIName:                event.API.APIName,
		APIID:                  event.API.APIID,
		APIType:                event.API.APIType,
		APIVersion:             event.API.APIVersion,
		APICreatorTenantDomain: event.API.APICreatorTenantDomain,
		APIMethod:              event.Operation.APIMethod,
		TargetResponseCode:     event.Target.TargetResponseCode,
		ProxyResponseCode:      event.ProxyResponseCode,
		CorrelationID:          event.MetaInfo.CorrelationID,
		RegionID:               event.MetaInfo.RegionID,
		GatewayType:            event.MetaInfo.GatewayType,
		KeyType:                event.Application.KeyType,
		ApplicationID:          event.Application.ApplicationID,
		ApplicationName:        event.Application.ApplicationName,
		ApplicationOwner:       event.Application.ApplicationOwner,
		UserAgentHeader:        event.UserAgentHeader,
		UserIP:                 event.UserIP,
		ErrorType:              "TARGET_CONNECTIVITY",
		RequestTimestamp:       event.RequestTimestamp.Format(timeFormat),
		ErrorCode:              event.Target.TargetResponseCode,
		ErrorMessage:           event.Target.ResponseCodeDetail,
		OrganizationID:         event.API.OrganizationID,
		ResponseCacheHit:       event.Target.ResponseCacheHit,
		EventType:              "fault",
		APIResourceTemplate:    event.Operation.APIResourceTemplate,
		APIContext:             event.API.APIContext,
	}
	if event.Target.TargetResponseCode == 404 {
		choreoResponseEvent.ErrorType = "OTHER"
	}

	choreoResponseEvent.EnvironmentID = "Default"
	choreoResponseEvent.GatewayType = "Onprem"
	choreoResponseEvent.KeyType = "PRODUCTION"
	if choreoResponseEvent.ApplicationOwner == "" {
		choreoResponseEvent.ApplicationOwner = "anonymous"
	}
	setDefaultUnknown(choreoResponseEvent)

	jsonString, err := util.ToJSONString(choreoResponseEvent)
	if err != nil {
		e.cfg.Logger.Error(err, "Error while converting to JSON string")
		return
	}
	e.cfg.Logger.Sugar().Debug(fmt.Sprintf("JSON string: %s", jsonString))
	eventData := &azeventhubs.EventData{
		Body: []byte(jsonString),
	}
	if eventData.Properties == nil {
		eventData.Properties = make(map[string]interface{})
	}
	eventData.Properties["token-hash"] = e.hashedToken
	eventData.CorrelationID = event.MetaInfo.CorrelationID
	eventData.MessageID = &event.MetaInfo.CorrelationID
	e.addEvent(eventData)
	e.cfg.Logger.Info("Fault event added to batch successfully")
}

func (e *Choreo) addEvent(event *azeventhubs.EventData) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.eventDataBatch == nil {
		newBatchOptions := &azeventhubs.EventDataBatchOptions{}
		batch, err := e.hub.NewEventDataBatch(context.TODO(), newBatchOptions)
		if err != nil {
			e.cfg.Logger.Error(err, "Error while creating new batch")
			return
		}
		e.eventDataBatch = batch
	}
	err := e.eventDataBatch.AddEventData(event, nil)
	if errors.Is(err, azeventhubs.ErrEventDataTooLarge) {
		err = e.hub.SendEventDataBatch(context.TODO(), e.eventDataBatch, nil)
		if err != nil {
			e.cfg.Logger.Error(err, "Error while sending batch")
			return
		}
		e.cfg.Logger.Info("Batch of events sent to Choreo successfully")
	}
}

func (e *Choreo) isFault(event *dto.Event) bool {
	return event.Target.ResponseCodeDetail != "via_upstream"
}
