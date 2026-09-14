# 🧠 Worker Stress Early Warning System

> **"A worker doesn't always need someone to tell them they're weak. Sometimes, they just need a system that reminds them they've been strong for too long."**

An **AI-assisted early warning system for workers** designed to detect patterns that may indicate increasing stress risk.

The system analyzes the accumulation of:

* ⏱️ Working hours
* 🏢 Overtime
* 🚗 Commuting duration
* 📈 Historical stress patterns
* 💬 User-reported experiences
* 📝 DASS-21 screening results

The goal is **not to diagnose mental health conditions**.

Instead, the system provides an early signal when a worker's workload, commuting burden, and psychological screening results indicate that their condition may deserve attention.

---

# 🎯 The Problem

For many workers, being tired is considered normal.

Working late is normal.

Commuting for hours every day is normal.

Working despite bad weather or exhaustion is normal.

For a parent supporting a family, sometimes there is simply no choice.

> **"I have to keep working because my family depends on me."**

The problem is that these individual situations may not look dangerous when viewed separately.

But when they accumulate over days, weeks, and months, the overall burden can become significant.

A worker may not realize that their stress risk is continuously increasing until their condition becomes serious.

### Our question is simple:

> **Can we detect the warning signs before the worker realizes something is wrong?**

---

# 💡 Our Solution

We built a **Worker Stress Early Warning System**.

This is **not primarily an AI mental-health chatbot**.

The chatbot is only one component of a larger system.

Our main focus is **early detection through accumulated worker patterns**.

The system combines:

```text
Working Hours
      +
Overtime
      +
Commuting Duration
      +
Stress History
      +
User Experience
      +
DASS-21 Screening
      ↓
   AI Analysis
      ↓
   Risk Score
      ↓
 Early Warning
      ↓
Recommendation
```

The key concept is:

# **Accumulation**

One long workday does not necessarily indicate a serious problem.

But a persistent pattern of:

> long working hours + frequent overtime + long commuting + increasing stress history

can become an important warning signal.

---

# 🧠 How the System Works

## 1. Monitor Worker Patterns

The application records relevant activity patterns such as:

* Working duration
* Commuting duration
* Overtime
* Daily activity
* Historical records

These records create a longitudinal view of the worker's workload.

---

## 2. Build Stress History

Instead of looking only at today's condition, the system maintains a **historical stress trend**.

For example:

```text
Week 1     35
Week 2     43
Week 3     51
Week 4     63
Week 5     72
```

The important signal is not only the current score.

It is the **trend over time**.

A consistently increasing pattern can become an early warning signal.

---

# 🤖 AI Analysis

The AI layer analyzes the available worker context and produces understandable insights and recommendations.

The system can consider:

* Recent workload
* Working hours
* Overtime
* Commuting burden
* Historical stress patterns
* User-reported experiences
* DASS-21 screening results

For example:

> **"Your workload and commuting duration have remained consistently high, while your stress history has increased. Consider reducing overtime and prioritizing recovery."**

The purpose of AI is to turn multiple data points into an understandable explanation for the worker.

---

# 🦙 Local AI with Ollama

The current prototype uses **Ollama** to run the LLM locally.

Unlike a cloud-first architecture, the current system operates on an **on-premise local server**.

```text
                 OFFICE NETWORK
                      │
        ┌─────────────┴─────────────┐
        │                           │
        ▼                           ▼
   Worker Device              Worker Device
    Flutter App                Flutter App
        │                           │
        └─────────────┬─────────────┘
                      │
                      ▼
              Local Office Server
                      │
              ┌───────┴────────┐
              │                │
              ▼                ▼
           FastAPI          Ollama
              │                │
              └───────┬────────┘
                      │
                      ▼
                 AI Analysis
```

### Why On-Premise?

The application deals with potentially sensitive worker information.

Keeping the current system on-premise provides an architecture where AI processing can happen inside the organization's local environment rather than requiring every conversation to be sent to an external cloud AI service.

This is particularly relevant for organizations that are concerned about:

* Employee privacy
* Internal data
* Network control
* AI processing location
* Organizational data governance

---

# 💬 AI Chatbot

The application provides a conversational interface where workers can describe what they are experiencing.

For example:

> "Saya akhir-akhir ini sering lembur dan perjalanan pulang bisa hampir 2 jam."

The AI can use this information together with the worker's existing context to provide an interpretation or recommendation.

However:

> **The chatbot is not the product itself.**

The chatbot is one input and interaction layer within the larger early warning system.

---

# 📝 DASS-21 Screening

The system integrates **DASS-21 (Depression Anxiety Stress Scales - 21 items)** as a screening component.

DASS-21 provides an additional psychological checkpoint.

For example:

```text
Worker Activity
      │
      ▼
Historical Pattern
      │
      ▼
DASS-21 Screening
      │
      ▼
AI Analysis
      │
      ▼
Risk Assessment
```

If the worker's historical pattern indicates elevated risk and their DASS-21 screening result falls into a severe stress category, the system can raise the risk assessment and recommend seeking professional support.

### ⚠️ Important

**DASS-21 is a screening instrument, not a diagnosis.**

This application does not replace:

* Psychologists
* Psychiatrists
* Doctors
* Other qualified healthcare professionals

The purpose of the system is to provide **early awareness and warning**, not to make a clinical diagnosis.

---

# 🚦 Risk Levels

The system can translate accumulated information into understandable risk levels.

### 🟢 LOW RISK

Worker patterns remain relatively stable.

**Recommendation:**

> Maintain a healthy work and recovery routine.

---

### 🟡 WARNING

The system detects an increasing burden.

Possible signals:

* Increasing working hours
* Frequent overtime
* Long commuting duration
* Increasing stress history

**Recommendation:**

> Your recent workload has been consistently high. Consider reducing overtime and prioritizing recovery.

---

### 🔴 HIGH RISK

Multiple signals indicate a significantly elevated risk pattern.

For example:

```text
High workload
      +
Frequent overtime
      +
Long commute
      +
Increasing stress history
      +
Severe DASS-21 screening
      ↓
HIGH RISK
```

The system can recommend that the worker consider consulting an appropriate mental-health professional.

---

# 📊 Why Historical Accumulation Matters

The system is designed around a simple idea:

> **Stress is not always an isolated event.**

Consider two workers.

### Worker A

```text
Normal working hours
Short commute
Rare overtime
Stable history
```

### Worker B

```text
10–12 hour workdays
Long daily commute
Frequent overtime
Increasing stress history
```

Looking at only one day may not show a significant difference.

But looking at the **accumulated pattern** provides much more context.

This is the core idea behind the early warning system.

---

# 💬 Why Not Just Use ChatGPT?

A general AI chatbot primarily understands what a user chooses to tell it.

Our system is designed to combine multiple sources of worker context.

```text
                General Chatbot

            "I'm feeling exhausted."
                       │
                       ▼
                  AI Response
```

Compared with:

```text
             Worker Early Warning System

             Working Hours
                   +
               Overtime
                   +
              Commute Time
                   +
             Stress History
                   +
             User Experience
                   +
                DASS-21
                   │
                   ▼
               AI Analysis
                   │
                   ▼
             Risk Assessment
                   │
                   ▼
             Early Warning
```

The key differentiator is **longitudinal context and accumulated burden**.

---

# 🏢 Current Deployment Model

The current prototype is designed for an **on-premise office environment**.

Workers connect to the application through the organization's local network.

```text
Employee 1 ──┐
Employee 2 ──┤
Employee 3 ──┼──► Office Local Server
Employee 4 ──┤          │
Employee 5 ──┘          ├── FastAPI
                         └── Ollama
```

### Current limitation

Because the current AI infrastructure is local/on-premise:

> **AI chatbot and AI recommendations are currently available only within the office/local server environment.**

This is intentional for the current prototype.

The future roadmap includes an online/cloud-enabled version.

---

# 💰 Business Model

The project can support both **B2C and B2B** models.

## 1. Free / Ad-Supported

A free version can be distributed through Google Play with advertising as one potential revenue source.

---

## 2. Premium Application

Users can purchase a premium version through the Google Play Store.

Potential premium features include:

* Advanced stress history
* Longer historical analysis
* More detailed insights
* Personalized recommendations
* Additional monitoring capabilities

---

## 3. B2B / Workplace Solution

Organizations can deploy the system for their employees using an on-premise environment.

Potential customers include:

* Companies
* Factories
* Offices
* Organizations with large commuting workforces

The organization could purchase a workplace deployment or enterprise package.

### B2B value proposition

Organizations can use the platform to help employees become more aware of accumulated workload and stress risk.

The system is intended as an **early-awareness tool**, not as a mechanism for diagnosing or penalizing employees.

---

# 🔐 Privacy & Data Isolation

Privacy is an important consideration because the application may process sensitive personal information.

The current architecture uses a local/on-premise server and customer-specific data isolation.

Customer-specific data includes:

* Chat history
* Stress history
* Monitoring data
* DASS-21 state
* AI analysis
* User configuration

The system is designed so that data belonging to one worker is not unintentionally mixed with another worker's data.

> **Worker data should belong to the worker — not to another user.**

---

# 🏗️ Technology Stack

## Frontend

* Flutter
* Android

## Backend

* Python
* FastAPI

## AI / LLM

* Ollama
* Local LLM inference
* Langflow

## Development

* IBM BOB
* GitHub

## Psychological Screening

* DASS-21

## Deployment

* Current: **On-Premise / Local Server**
* Future: **Online / Cloud**

---

# 🗺️ Roadmap

## ✅ Current Prototype

* [x] Worker activity monitoring
* [x] Working-hour tracking
* [x] Commuting-time tracking
* [x] Stress history
* [x] AI analysis
* [x] Local LLM using Ollama
* [x] On-premise server
* [x] AI conversational interface
* [x] DASS-21 screening
* [x] Early warning concept
* [x] Customer data isolation

## 🔄 Next Development

### 🌐 Online Version

Move from a local-only architecture toward an online platform.

Potential architecture:

```text
Flutter App
     │
     ▼
Cloud Backend
     │
     ├── AI Service
     ├── Database
     └── Risk Analysis
```

This would allow workers to access the service outside the office network.

---

### 🏃 Physical Activity Integration

Future versions will incorporate **physical activity** as an additional signal.

Potential inputs may include:

* Daily activity
* Exercise
* Movement patterns
* Activity duration

The purpose is to provide another dimension when estimating accumulated worker burden.

Future model:

```text
Working Hours
       +
Commute
       +
Overtime
       +
Stress History
       +
DASS-21
       +
Physical Activity
       │
       ▼
   AI Analysis
       │
       ▼
 Stress Risk Assessment
       │
       ▼
 Early Warning
```

---

# 🌱 Long-Term Vision

The long-term vision is to move mental-health awareness from **reactive** to **preventive**.

### Traditional approach

```text
Problem
   ↓
Condition becomes serious
   ↓
Person realizes something is wrong
   ↓
Seek help
```

### Our approach

```text
Daily Worker Data
       ↓
Pattern Detection
       ↓
Accumulation
       ↓
Early Warning
       ↓
Self Awareness
       ↓
Preventive Action
       ↓
Professional Support
```

We believe that the earlier a worker recognizes an unhealthy pattern, the more opportunities they may have to take action.

---

# ❤️ Human-Centered Motivation

This project comes from a simple reality.

A worker may continue working because their family depends on them.

A parent may continue commuting through heavy rain.

Someone may accept overtime because there are bills to pay.

Someone may ignore exhaustion because:

> **"This is just part of working."**

Our goal is not to tell workers that they are weak.

Our goal is to give them a signal.

> **"Your current pattern deserves attention."**

Because sometimes:

> **A worker doesn't need someone to tell them they're weak.**

> **They need a system that reminds them they've been strong for too long.**

---

# ⚠️ Disclaimer

This project is a **hackathon prototype and early-warning/awareness system**.

It is not intended to diagnose depression, anxiety, stress disorders, burnout, or any other medical or psychological condition.

DASS-21 is used as a screening instrument.

AI-generated insights are informational and should not replace professional medical or psychological assessment.

If a user is experiencing significant distress or receives concerning screening results, they should seek appropriate professional support.

---

# 🚀 Project Status

> **🚧 Hackathon Prototype — In Development**

The current prototype demonstrates an AI-assisted early warning system for worker stress using locally hosted AI infrastructure.

The project is currently focused on validating the concept of combining:

**Work + Commute + History + Psychological Screening + AI**

into a single early-warning experience.

---

# 🎯 Our Vision

## **Detect the pattern before it becomes the problem.**

### **Work. Commute. Accumulate. Detect. Act.**
