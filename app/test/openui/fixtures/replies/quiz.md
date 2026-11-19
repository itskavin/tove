Here's a short sleep-habits check. Answer for the past month; it takes about a minute.

```openui
root = Card([quiz])
quiz = Quiz("Sleep habits check", [q1, q2, q3, q4, q5, q6], "Sample Sleep Scale (example)", "Screening, not a diagnosis.")
q1 = Question("How often do you have trouble falling asleep?", ["Never", "Rarely", "Sometimes", "Often", "Very often"])
q2 = Question("How often do you wake up during the night?", ["Never", "Rarely", "Sometimes", "Often", "Very often"])
q3 = Question("How often do you feel tired after a full night's sleep?", ["Never", "Rarely", "Sometimes", "Often", "Very often"])
q4 = Question("How often do you use your phone in bed?", ["Never", "Rarely", "Sometimes", "Often", "Very often"])
q5 = Question("How often do you nap during the day?", ["Never", "Rarely", "Sometimes", "Often", "Very often"])
q6 = Question("How often do you drink caffeine after 4 pm?", ["Never", "Rarely", "Sometimes", "Often", "Very often"])
```
