package scaler

import (
	"log"
	"math"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/autoscaling"
	"github.com/buildkite/elastic-ci-stack-for-aws/lambdas/ec2-agent-scaler/buildkite"
)

type Params struct {
	AutoScalingGroupName string
	AgentsPerInstance    int
	BuildkiteAgentToken  string
	BuildkiteQueue       string
	UserAgent            string
}

type History struct {
	LastScaleIn      time.Time
	LastScaleOut     time.Time
	LastDesiredCount int64
}

type Scaler struct {
	History *History
	ASG     interface {
		Describe() (ASGDetails, error)
		SetDesiredCapacity(count int64) error
	}
	Buildkite interface {
		GetScheduledJobCount() (int64, error)
	}
	AgentsPerInstance int
}

type ASGDetails struct {
	DesiredCount int64
	MinSize      int64
	MaxSize      int64
}

func New(history *History, params Params) *Scaler {
	return &Scaler{
		History: history,
		ASG: &asgDriver{
			name: params.AutoScalingGroupName,
		},
		Buildkite: &buildkiteDriver{
			agentToken: params.BuildkiteAgentToken,
			queue:      params.BuildkiteQueue,
		},
		AgentsPerInstance: params.AgentsPerInstance,
	}
}

func (s *Scaler) Run() error {
	count, err := s.Buildkite.GetScheduledJobCount()
	if err != nil {
		return err
	}

	var desired int64
	if count > 0 {
		desired = int64(math.Ceil(float64(count) / float64(s.AgentsPerInstance)))
	}

	current, err := s.ASG.Describe()
	if err != nil {
		return err
	}

	if desired > current.MaxSize {
		log.Printf("⚠️  Desired count exceed MaxSize, capping at %d", current.MaxSize)
		desired = current.MaxSize
	} else if desired < current.MinSize {
		log.Printf("⚠️  Desired count is less than MinSize, capping at %d", current.MinSize)
		desired = current.MinSize
	}

	t := time.Now()

	if desired > current.DesiredCount {
		log.Printf("Scaling OUT 📈 to %d instances (currently %d)", desired, current.DesiredCount)

		if !s.History.LastScaleOut.IsZero() {
			log.Printf("Last scale out was %v ago", time.Now().Sub(s.History.LastScaleOut))
		}

		err = s.ASG.SetDesiredCapacity(desired)
		if err != nil {
			return err
		}

		log.Printf("↳ Set desired to %d (took %v)", desired, time.Now().Sub(t))
		s.History.LastDesiredCount = desired
		s.History.LastScaleOut = time.Now()
	} else if current.DesiredCount > desired {
		log.Printf("Scaling IN 📉 to %d instances (currently %d)", desired, current.DesiredCount)

		if !s.History.LastScaleIn.IsZero() {
			log.Printf("Last scale in was %v ago", time.Now().Sub(s.History.LastScaleIn))
		}

		err = s.ASG.SetDesiredCapacity(desired)
		if err != nil {
			return err
		}

		log.Printf("↳ Set desired to %d (took %v)", desired, time.Now().Sub(t))
		s.History.LastDesiredCount = desired
		s.History.LastScaleIn = time.Now()
	} else {
		log.Printf("No scaling required, currently %d", current.DesiredCount)
	}

	return nil
}

type asgDriver struct {
	name string
}

func (a *asgDriver) Describe() (ASGDetails, error) {
	svc := autoscaling.New(session.New())
	input := &autoscaling.DescribeAutoScalingGroupsInput{
		AutoScalingGroupNames: []*string{
			aws.String(a.name),
		},
	}

	result, err := svc.DescribeAutoScalingGroups(input)
	if err != nil {
		return ASGDetails{}, err
	}

	return ASGDetails{
		DesiredCount: int64(*result.AutoScalingGroups[0].DesiredCapacity),
		MinSize:      int64(*result.AutoScalingGroups[0].MinSize),
		MaxSize:      int64(*result.AutoScalingGroups[0].MaxSize),
	}, nil

}

func (a *asgDriver) SetDesiredCapacity(count int64) error {
	svc := autoscaling.New(session.New())
	input := &autoscaling.SetDesiredCapacityInput{
		AutoScalingGroupName: aws.String(a.name),
		DesiredCapacity:      aws.Int64(count),
		HonorCooldown:        aws.Bool(false),
	}

	_, err := svc.SetDesiredCapacity(input)
	if err != nil {
		return err
	}

	return nil
}

type buildkiteDriver struct {
	agentToken string
	queue      string
}

func (a *buildkiteDriver) GetScheduledJobCount() (int64, error) {
	return buildkite.NewBuildkiteClient(a.agentToken).GetScheduledJobCount(a.queue)
}

type DryRunASG struct {
}

func (a *DryRunASG) SetDesiredCapacity(count int64) error {
	return nil
}
