# Wiring Guide for PicoTDS

## Hardware Components

- Raspberry Pi Pico W
- TDS Meter Shield (e.g., Gravity: Analog TDS Sensor/Meter)
- Breadboard (optional)
- Jumper wires
- USB cable for power/programming

## Common TDS Shield Pinouts

### Generic TDS Shield (Analog Output)

```
TDS Shield          Pico W
-----------         ------
VCC (3.3V/5V)  -->  3V3(OUT) or VSYS
GND            -->  GND (any GND pin)
Analog Output  -->  GP26 (ADC0)
```

### Gravity TDS Sensor (DFRobot)

```
Gravity TDS          Pico W
-----------         ------
Red (VCC)      -->  3V3(OUT) or VSYS
Black (GND)    -->  GND
Blue (Signal)  -->  GP26 (ADC0)
```

## Pico W Pin Reference

### Power Pins
- **VSYS**: 1.8V-5.5V input (from USB or external source)
- **3V3(OUT)**: 3.3V output (max 300mA)
- **GND**: Ground (multiple pins available)

### ADC Pins (GP26-GP28)
- **GP26 (ADC0)**: Analog input channel 0
- **GP27 (ADC1)**: Analog input channel 1
- **GP28 (ADC2)**: Analog input channel 2 (also ADC2)

Note: Pico ADC is 12-bit (0-4095) but MicroPython provides 16-bit (0-65535)

### GPIO Pins
- GP0-GP22: General purpose I/O
- GP26-GP28: ADC pins (can also be used as GPIO)

## Wiring Diagram

```
┌─────────────────┐
│   Pico W        │
│                 │
│  [USB]          │
│                 │
│  GP26 [ADC0]───┐│
│                ││
│  3V3(OUT)──────┼│─── To TDS VCC
│                ││
│  GND───────────┼│─── To TDS GND
│                ││
└────────────────┘│
                 │
        ┌────────┘
        │
┌───────▼────────┐
│  TDS Shield    │
│                │
│  VCC  ─────────┘
│  GND
│  OUT ──────────┘
└────────────────┘
```

## Adding Temperature Sensor (Optional)

For temperature compensation, add a DS18B20:

```
DS18B20          Pico W
-------         ------
VCC        -->  3V3(OUT)
GND        -->  GND
DATA       -->  GP27 (with 4.7kΩ pull-up to VCC)
```

### DS18B20 Wiring Detail

```
3V3(OUT) ───┬────── VCC (DS18B20)
            │
           [4.7kΩ]
            │
GP27 ───────┼────── DATA (DS18B20)
            │
GND ─────────┴────── GND (DS18B20)
```

## Power Considerations

### USB Power
- Pico W can be powered via USB (5V)
- USB provides up to 500mA (sufficient for most TDS shields)

### External Power
For standalone operation:
- Use 5V power supply connected to VSYS
- Ensure TDS shield voltage matches (check shield specs)
- Add capacitor (100µF) near sensor for stable readings

### Voltage Levels
- Pico GPIO: 3.3V maximum
- TDS shield output: typically 0-2.5V (safe for Pico ADC)
- If shield outputs 5V, use voltage divider:
  ```
  Shield OUT ──[10kΩ]──┬── GP26
                         │
                        [10kΩ]
                         │
                        GND
  ```

## Connection Checklist

Before powering on:
- [ ] VCC connected to correct voltage (3.3V or 5V based on shield)
- [ ] GND connected (common ground is critical)
- [ ] Analog output connected to ADC pin (GP26 by default)
- [ ] No reversed polarity
- [ ] Secure connections (no loose wires)
- [ ] Shield away from USB port to avoid interference

## Testing the Connection

1. Power on the Pico W
2. Open serial monitor (115200 baud)
3. Run the test:
   ```python
   import tds_sensor
   sensor = tds_sensor.TDSSensor()
   sensor.read_tds()
   ```
4. Expected output:
   - Non-zero voltage reading (0.1V - 2.5V typical)
   - TDS value between 0-1000 ppm (in air or water)

## Troubleshooting

### Reading is 0 or very low
- Check VCC connection
- Verify GND is connected
- Test ADC with known voltage source

### Reading is maximum (65535)
- Check for short circuit
- Verify voltage is not exceeding 3.3V
- Check pin configuration

### Erratic readings
- Add capacitor (100µF) between VCC and GND near sensor
- Check for loose connections
- Move away from noise sources (motors, USB cables)

### Sensor not detected
- Verify pin number in config matches wiring
- Check if ADC pin is damaged
- Try different ADC pin (GP27 or GP28)
