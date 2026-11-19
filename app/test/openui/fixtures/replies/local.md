I'd start with **Sample Mind Clinic**: it lists adult ADHD assessments and is the closest, about 400 m away. Example Neuro Centre is a good second option for psychological testing.

```openui
root = Card([head, places, map, tip, next])
head = CardHeader("Adult ADHD assessment near you", "3 options within 3 km")
places = Places([p1, p2, p3])
p1 = Place("place:sample-clinic-0001", "Sample Mind Clinic", null, "Adult ADHD assessment · ₹3,500 (clinic site)", "4.8 · 120 reviews", "Practo")
p2 = Place("place:sample-centre-0002", "Example Neuro Centre", null, "Psychological testing · price not listed", "4.5 · 64 reviews", "Justdial")
p3 = Place("place:sample-health-0003", "Placeholder Health Hospital", null, "Psychiatry OPD · ₹800 consultation")
map = Map([p1, p2, p3])
tip = Callout("info", "Before you book", "Ask whether they assess adults, the total fee, and how many sessions it takes.")
next = Buttons([Button("Start ADHD screening", null, "primary"), Button("Find online options instead"), Button("Remind me to call tomorrow")])
```

Sample Mind Clinic's fee is from its own site; I couldn't verify the others' prices.[^1]

[^1]: [Adult ADHD assessment](https://clinic.example/adhd) — Sample Mind Clinic.
