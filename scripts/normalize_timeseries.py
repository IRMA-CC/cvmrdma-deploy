#!/usr/bin/env python3

import fileinput
from pathlib import Path
import pandas as pd

SIDE=[]
EVENTS=[]
T=[]


PREFIX="TIME "
for line in fileinput.input():
    if(line[:len(PREFIX)] == PREFIX):
        data = line[len(PREFIX):]
        event, t = data.split(",")

        SIDE.append(Path(fileinput.filename()).stem)
        EVENTS.append(event)
        T.append(int(t))

df = pd.DataFrame(data={"side": SIDE, "event": EVENTS, "t": T})

df.sort_values("t", inplace=True, ignore_index=True)

min_t = df.loc[0, "t"]

df.loc[:, "t"] -= min_t

df.loc[:, "dt"] = df.loc[:, "t"].diff()

with pd.option_context('display.max_rows', 10000):
    print(df.loc[0:1000, :])

