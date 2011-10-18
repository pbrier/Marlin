#include "Screen.h"
#include <string.h>
#define LCD_DEBUG

///-----------------------------------------------------

#define FUNCTION_8BIT        0x10
#define FUNCTION_4BIT        0x00
#define FUNCTION_MULTILINE   0x08
#define FUNCTION_ONELINE     0x00
#define FUNCTION_5x10        0x04
#define FUNCTION_5x8         0x00

#define DISPLAY_DISPLAY_ON     0x04
#define DISPLAY_DISPLAY_OFF    0x00
#define DISPLAY_CURSOR_ON      0x02
#define DISPLAY_CURSOR_OFF     0x00
#define DISPLAY_BLINK_ON       0x01
#define DISPLAY_BLINK_OFF      0x00

#define ENTRY_LEFTTORIGHT      0x02
#define ENTRY_RIGHTTOLEFT      0x00
#define ENTRY_SHIFT_ON         0x01    // Shift display on write
#define ENTRY_SHIFT_OFF        0x00    // Do not shift display on write

/*
    Initialization arguments 
*/

#define FUNCTION_ARGS  FUNCTION_4BIT | FUNCTION_MULTILINE | FUNCTION_5x8
#define DISPLAY_ARGS   DISPLAY_DISPLAY_ON | DISPLAY_CURSOR_OFF | DISPLAY_BLINK_OFF
#define ENTRY_CMD_ARGS ENTRY_LEFTTORIGHT | ENTRY_SHIFT_OFF


// lcdInit - Needs to be called once to setup the LCD display and interrupt before the 
// display can be used.
void lcdInit();

// Create a custom character in one of the first 8 places
// NOTE: must be called after lcdIni tand before anyother methods
void lcdCreateChar(const uint8_t location, const uint8_t charmap[]);

// lcdLockBuffer - Called to setup a buffer to write to returns true on success and should
// be followed by a matching call to lcdWriteBuffer(). A return value of false means there
// isn't a buffer free to write to.
bool lcdLockBuffer();

// lcdWriteBuffer - Called at the end of an update to prepare the result for display.
void lcdWriteBuffer();

// Set the current write position in the buffer.
void lcdSetCursor(const int col, const int row);

// Print a nul treminated string of characters caller should limit to the remaining length 
// of the current row. This method advances the current write postition.
void lcdPrint(char* pString);

// Print a byte to the buffer and advance the current write postition.
void lcdPrint(uint8_t value);

// Lock buffer and write it in one call returns true on success, false if no buffer
// was available
bool lcdWriteBuffer(uint8_t *pBuffer);


void lcdCommandNibble(uint8_t value);
void lcdCommand(uint8_t value);
void lcdSyncWrite(uint8_t value);
void lcdSyncWriteNibble(uint8_t value);


inline void lcdSetDataBits(uint8_t nibble)
{         
    WRITE(LCD_DB4_PIN, (nibble & _BV(0)) ? HIGH : LOW );
    WRITE(LCD_DB5_PIN, (nibble & _BV(1)) ? HIGH : LOW );
    WRITE(LCD_DB6_PIN, (nibble & _BV(2)) ? HIGH : LOW );
    WRITE(LCD_DB7_PIN, (nibble & _BV(3)) ? HIGH : LOW );
}


/*
    A double buffered interrupt driven LCD library
*/


struct LCD_BUFFER
{
    volatile boolean ReadReady;
    volatile boolean WriteReady;
    uint8_t Buffer[LCD_ROWS * LCD_COLS];
    uint8_t *pEnd;
    LCD_BUFFER *pNext;
};

// The following protect the buffer's "Ready" states and interruptState
#define ISR_ENTER if(ops != 0) return // Don't process interrupt if in critical block
#define CODE_ENTER     ++ops          // Enter critical block
#define CODE_LEAVE     --ops          // Leave critical block

#define INTERRUPTSTATE_IDLE        0    // Do nothing at a slow rate
#define INTERRUPTSTATE_CMD_HI1     1    // Home cursor, send first nibble - RS Low, E High, fast rate
#define INTERRUPTSTATE_CMD_LO1     2    // Home cursor, end first nibble - E Low
#define INTERRUPTSTATE_CMD_HI2     3    // Home cursor, send second nibble - E High 
#define INTERRUPTSTATE_CMD_LO2     4    // Home cursor, end second nibble - E Low
#define INTERRUPTSTATE_CMD_END     5    // Home cursor, end the command - RS High
#define INTERRUPTSTATE_E_GOHI      6    // Data loop, start send data - E High
#define INTERRUPTSTATE_E_GOLO      7    // Data loop, end send data - E Low

#define INITIALIZE_CMD         0x03
#define SET_4BIT_CMD           0x02

#define CLEAR_CMD              0x01 // Clear the display
#define ENTRY_MODE_CMD         0x04
#define DISPLAY_CMD            0x08
#define FUNC_SET_CMD           0x20
#define WRITE_CGRAM_CMD        0x40
#define HOME_CURSOR_CMD        0x80 // Set the LCD to Addr 0

#define TIMER_A_VALUE          0
#define TIMER_B_VALUE          _BV(CS32) | _BV(WGM32); //1/128th, CTC = 16 microsecond timer
#define INTERRUPT_IDLE         128  // Slower rate when we aren't updating
#define INTERRUPT_BUSY         8    // Faster rate while we update (must be > 37 microseconds)

// The Timer interrupt we'll use need to update ISR definition if this changes
// everything else should be macro hackery
#define LcdInterruptNumber 4

#define MkTimerRegisterA(x)      TCCR ## x ## A
#define MkTimerRegisterB(x)      TCCR ## x ## B
#define MkOutCmpRegisterA(x)     OCR ## x ## A
#define MkTimerMaskRegister(x)   TIMSK ## x
#define MkTimerMaskBit(x)        OCIE ## x ## A

#define TimerA(x)    MkTimerRegisterA(x)
#define TimerB(x)    MkTimerRegisterB(x)
#define OutCmpA(x)   MkOutCmpRegisterA(x)
#define TimerMask(x) MkTimerMaskRegister(x)
#define TimerBit(x)  MkTimerMaskBit(x)

static struct LCD_BUFFER lcdBuffers[2];

static LCD_BUFFER *pRead;
static uint8_t *pReadCurrent;
static uint8_t readTick;

static LCD_BUFFER *pWriteNext;
static LCD_BUFFER *pWrite;
static uint8_t *pWriteCurrent;

static volatile uint8_t interruptState;
static volatile uint8_t ops;

void lcdInit()
{
    SET_OUTPUT(LCD_RS_PIN);
    SET_OUTPUT(LCD_E_PIN);
  
    SET_OUTPUT(LCD_DB4_PIN);
    SET_OUTPUT(LCD_DB5_PIN);
    SET_OUTPUT(LCD_DB6_PIN);
    SET_OUTPUT(LCD_DB7_PIN);

    delayMicroseconds(50000);            // 15ms after 4.5V or 40ms after 2.7V
    lcdCommandNibble(INITIALIZE_CMD);
    delayMicroseconds(4100);             // >4.1ms
    lcdCommandNibble(INITIALIZE_CMD);
    delayMicroseconds(200);              // > 100
    lcdCommandNibble(INITIALIZE_CMD);
    
    lcdCommandNibble(SET_4BIT_CMD); // Set 4 bit interface
    
    lcdCommand(FUNC_SET_CMD | FUNCTION_ARGS); 
    lcdCommand(DISPLAY_CMD | DISPLAY_ARGS); 
    lcdCommand(CLEAR_CMD); 
    lcdCommand(ENTRY_MODE_CMD | ENTRY_CMD_ARGS); 
    
    ops = 0; // Used for critical sections
    
    lcdBuffers[0].ReadReady = false;
    lcdBuffers[0].WriteReady = true;
    lcdBuffers[0].pEnd = lcdBuffers[0].Buffer + (LCD_ROWS * LCD_COLS);
    lcdBuffers[0].pNext = &lcdBuffers[1];
    
    lcdBuffers[1].ReadReady = false;
    lcdBuffers[1].WriteReady = true;
    lcdBuffers[1].pEnd = lcdBuffers[1].Buffer + (LCD_ROWS * LCD_COLS);
    lcdBuffers[1].pNext = &lcdBuffers[0];
    
    interruptState = INTERRUPTSTATE_IDLE;
    
    pRead = &lcdBuffers[0];
    pReadCurrent = pRead->Buffer;
    readTick = 0x01;
    //readTicks initialized in the interrupt
    
    pWriteNext = &lcdBuffers[0];
    pWrite = 0;
    pWriteCurrent = 0;
     
    if(1)
    {
    TimerMask(LcdInterruptNumber) |= _BV(TimerBit(LcdInterruptNumber));
    TimerA(LcdInterruptNumber) = TIMER_A_VALUE;
    TimerB(LcdInterruptNumber) = TIMER_B_VALUE;
    OutCmpA(LcdInterruptNumber) = INTERRUPT_IDLE; 
    }
}

void lcdCreateChar(const uint8_t location, const uint8_t charmap[])
{
    int i;
    
    lcdCommand(WRITE_CGRAM_CMD | ((location & 0x07) << 3)); // Lock location to 0-7 and multiple by 8
    
    for (i = 0; i < 8; ++i)
    {
        lcdSyncWrite(charmap[i]);
    }
}

void lcdSetCursor(const int8_t col, const int8_t row)
{
    switch (row)
    {
        case 0:
            pWriteCurrent = pWrite->Buffer + col;
            break;
            
        case 1:
            pWriteCurrent = pWrite->Buffer + 2 * LCD_COLS + col;
            break;
            
        case 2:
            pWriteCurrent = pWrite->Buffer + LCD_COLS + col;
            break;
            
        case 3:
            pWriteCurrent = pWrite->Buffer + 3 * LCD_COLS + col;
            break;
    }
}

void lcdPrint(char *pString)
{
    while (*pString)
    {
        *pWriteCurrent++ = *pString++;
    }
}

void lcdPrint(uint8_t value)
{
    *pWriteCurrent++ = value;
}

bool lcdLockBuffer()
{
    pWrite = pWriteNext;

    CODE_ENTER; // Syncronize WriteReady with ISR
    
    if (!pWrite->WriteReady)
    {
        //Serial.print((int)interruptState);
        CODE_LEAVE;
        pWrite = 0;
        return false;
    }
    pWrite->WriteReady = false;
    
    CODE_LEAVE; // End syncronize WriteReady with ISR
    
    pWriteCurrent = pWrite->Buffer;
    memset(pWriteCurrent, 0x20, LCD_ROWS * LCD_COLS); 
    return true;
}

void lcdWriteBuffer()
{
    CODE_ENTER; // Synchronize ReadReady and writeState with ISR
    
    pWrite->ReadReady = true;
    if (interruptState == INTERRUPTSTATE_IDLE)
    {
        interruptState = INTERRUPTSTATE_CMD_HI1;
    }
    
    CODE_LEAVE; // End synchronize ReadReady and writeState with ISR

    pWriteNext = pWrite->pNext;
    pWrite = 0;
    pWriteCurrent = 0;
}

bool lcdWriteBuffer(uint8_t *pBuffer)
{
    CODE_ENTER; // Syncronize WriteReady with ISR
    
    if (!pWriteNext->WriteReady)
    {
        //Serial.print((int)interruptState);
        CODE_LEAVE;
        return false;
    }
    pWriteNext->WriteReady = false;
    
    CODE_LEAVE; // End syncronize WriteReady with ISR
    
    memcpy(pWriteNext->Buffer, pBuffer, LCD_ROWS * LCD_COLS); 
    
    CODE_ENTER; // Synchronize ReadReady and writeState with ISR
    
    pWriteNext->ReadReady = true;
    if (interruptState == INTERRUPTSTATE_IDLE)
    {
        interruptState = INTERRUPTSTATE_CMD_HI1;
    }
    
    CODE_LEAVE; // End synchronize ReadReady and writeState with ISR

    pWriteNext = pWriteNext->pNext;
    
    return true;
}

/************************************************************************

Internal functions

************************************************************************/


#ifdef LCD_DEBUG

void DebugState(struct LCD_BUFFER *pBuffer)
{
    int i,j, k;
    Serial.print("Buffer=");
    Serial.println((int)pBuffer);
    if (pBuffer == 0)
    {
        return;
    }
    Serial.print("WR=");
    Serial.println((int)pBuffer->WriteReady);
    Serial.print("RR=");
    Serial.println((int)pBuffer->ReadReady);
    for (i = 0, k = 0; i < LCD_ROWS; ++i)
    {
        for (j = 0; j <  LCD_COLS; ++j)
        {
            Serial.print(pBuffer->Buffer[k],HEX);
            Serial.print(' ');
            ++k;
        }
        Serial.println();
    }
    Serial.print("e=");
    Serial.println((int)pBuffer->pEnd);
    Serial.print("n=");
    Serial.println((int)pBuffer->pNext);
}

void DebugState()
{
    cli();
    Serial.println();
    Serial.print("pRead ");
    DebugState(pRead);
    Serial.print("pReadCurrent=");
    Serial.println((int)pReadCurrent);
    Serial.print("readTick=");
    Serial.println((int)readTick);
    
    Serial.print("pWrite ");
    DebugState(pWrite);
    Serial.print("pWriteNext ");
    DebugState(pWriteNext);
    Serial.print("pWriteCurrent=");
    Serial.println((int)pWriteCurrent);
    
    Serial.print("ops=");
    Serial.println((int)ops);

    Serial.print("interruptState=");
    Serial.println((int)interruptState);
    sei();
}

#endif

void lcdCommand(uint8_t value)
{
    WRITE(LCD_RS_PIN, LOW);
    lcdSyncWrite(value);
    WRITE(LCD_RS_PIN, HIGH);
}

void lcdCommandNibble(uint8_t value)
{
    WRITE(LCD_RS_PIN, LOW);
    lcdSyncWriteNibble(value);
    WRITE(LCD_RS_PIN, HIGH);
}

void lcdSyncWrite(uint8_t value)
{
    lcdSyncWriteNibble(value >> 4);
    lcdSyncWriteNibble(value);
}

void lcdSyncWriteNibble(uint8_t value)
{
    lcdSetDataBits(value);        
    
    WRITE(LCD_E_PIN, HIGH);
    
    delayMicroseconds(2);
    
    WRITE(LCD_E_PIN, LOW);
    
    delayMicroseconds(50);
}



void handleLcd();

ISR(TIMER4_COMPA_vect)
{
//    static volatile bool running = false;
//    if(running)
//    {
//        return;
//    }force_lcd_update=false
//    running = true;
    
    handleLcd();
    
//    running = false;
}

void handleLcd()
{
    uint8_t writeByte;
    ISR_ENTER;
    // We know the user isn't altering buffer state
    // and we will complete before they execute again
    if(interruptState == INTERRUPTSTATE_IDLE)
    {
        OutCmpA(LcdInterruptNumber) = INTERRUPT_IDLE; // Minimize overhead while still reponsive
        return;
    }
    
    switch (interruptState)
    {
        case INTERRUPTSTATE_CMD_HI1:
            OutCmpA(LcdInterruptNumber) = INTERRUPT_BUSY; // Fire faster while updating
            WRITE(LCD_RS_PIN, LOW);
            lcdSetDataBits(HOME_CURSOR_CMD >> 4);
            WRITE(LCD_E_PIN, HIGH);
            
            interruptState = INTERRUPTSTATE_CMD_LO1;
            return;
            
        case INTERRUPTSTATE_CMD_LO1:
            WRITE(LCD_E_PIN, LOW);
            
            interruptState = INTERRUPTSTATE_CMD_HI2;
            return;
            
        case INTERRUPTSTATE_CMD_HI2:
            lcdSetDataBits(HOME_CURSOR_CMD);
            WRITE(LCD_E_PIN, HIGH);
            
            interruptState = INTERRUPTSTATE_CMD_LO2;
            return;
           
        case INTERRUPTSTATE_CMD_LO2:
            WRITE(LCD_E_PIN, LOW);
            
            interruptState = INTERRUPTSTATE_CMD_END;
            return;
            
        case INTERRUPTSTATE_CMD_END:
            WRITE(LCD_RS_PIN, HIGH);
            
            interruptState = INTERRUPTSTATE_E_GOHI;
            return;
            
        case INTERRUPTSTATE_E_GOHI:
            if (readTick & 0x01)
            {
                writeByte = (*pReadCurrent >> 4);
            }
            else
            {
                writeByte = *pReadCurrent;
                ++pReadCurrent;
            }
            ++readTick;
            lcdSetDataBits(writeByte);
            WRITE(LCD_E_PIN, HIGH);
            
            interruptState = INTERRUPTSTATE_E_GOLO;
            return;
            
        case INTERRUPTSTATE_E_GOLO:
            WRITE(LCD_E_PIN, LOW);
            
            if(pReadCurrent >= pRead->pEnd || pRead->pNext->ReadReady)
            {
                if (!(readTick & 0x01))
                {
                    // Write a full byte before switching
                    interruptState = INTERRUPTSTATE_E_GOHI;
                    return;
                }
                pRead->WriteReady = true;
                pRead->ReadReady = false;
                
                pRead = pRead->pNext;
                pReadCurrent = pRead->Buffer;
                readTick = 0x01;
              
                // If we have data write it else go to idle state
                interruptState = (pRead->ReadReady) ? INTERRUPTSTATE_CMD_HI1 : INTERRUPTSTATE_IDLE;
            }
            else
            {
                interruptState = INTERRUPTSTATE_E_GOHI;
            }  
            return;
    }
}

///-----------------------------------------------------


Screen::Screen()
{
  //any init here fails. 
  //delay(100);
  //lcdInit();
}

void Screen::init()
{
    lcdInit();
}

Screen::Screen(char* baseScreen)
{
    for (int row = 0; row < LCD_ROWS; ++row)
    {
        printRow(row, baseScreen + row * LCD_COLS);
    }
    pCurrent = buffer;
}


void Screen::clear()
{
    memset(buffer, ' ', LCD_ROWS * LCD_COLS);
    pCurrent = buffer; 
    buffer[0]='A';buffer[1]='B';
}

void Screen::begin(uint8_t x, uint8_t y)
{
    //ignore
  
}
void Screen::setCursor(const int8_t col, const int8_t row)
{
    setCursorRow(row);
    pCurrent += col;
}

void Screen::setCursorRow(const int8_t row)
{
    switch (row)
    {
    case 0:
        pCurrent = buffer;
        break;

    case 1:
        pCurrent = buffer + 2 * LCD_COLS;
        break;

    case 2:
        pCurrent = buffer + LCD_COLS;
        break;

    case 3:
        pCurrent = buffer + 3 * LCD_COLS;
        break;
    }
}

void Screen::print(char ch)
{
    *pCurrent++ = ch;
}

void Screen::print(char *text)
{
    while (*text)
    {
        *pCurrent++ = *text++;
    }
}

void Screen::print(char *text, int count)
{
    while (*text && count)
    {
        *pCurrent++ = *text++;
        --count;
    }
    
    while (count)
    {
        *pCurrent++ = ' ';
        --count;
    }
}

void Screen::printRow(int row, char *text)
{
    setCursorRow(row);
    print(text, LCD_COLS);
}

bool Screen::display()
{
    static long lasttime=0;
    long ms=millis();
    if(ms<lasttime+100)
      return false;
    lasttime=ms;
    return lcdWriteBuffer((uint8_t*)buffer);
}

// Print float with +123.4 format
void Screen::printFloat31(float value)
{
    int total;
    int digit;
    if (value >= 0)
    {
        *pCurrent++ = '+';
        value *= 0.01;
    }
    else
    {
        *pCurrent++ = '-';
        value *= -0.01;
    }

    digit = value;  

    *pCurrent++ = digit + '0'; 
    total = digit * 10; 
    value *= 10.0;
    digit = (int)value - total;

    *pCurrent++ = digit + '0';
    total += digit;
    total *= 10; 
    value *= 10.0;
    digit = (int)value - total;

    *pCurrent++ = digit + '0'; 
    total += digit;
    total *= 10; 
    value *= 10.0;
    digit = (int)value - total;

    *pCurrent++ = '.';

    *pCurrent++ = digit + '0';
}

//  Print float with +1234.5 format
void Screen::printFloat41(float value)
{
    int total;
    int digit;
    if (value >= 0)
    {
        *pCurrent++ = '+';
        value *= 0.001;
    }
    else
    {
        *pCurrent++ = '-';
        value *= -0.001;
    }

    digit = value;  

    *pCurrent++ = digit + '0'; 
    total = digit * 10; 
    value *= 10.0;
    digit = (int)value - total;

    *pCurrent++ = digit + '0';
    total += digit;
    total *= 10; 
    value *= 10.0;
    digit = (int)value - total;

    *pCurrent++ = digit + '0';
    total += digit;
    total *= 10; 
    value *= 10.0;
    digit = (int)value - total;

    *pCurrent++ = digit + '0'; 
    total += digit;
    total *= 10; 
    value *= 10.0;
    digit = (int)value - total;

    *pCurrent++ = '.';

    *pCurrent++ = digit + '0';
}

void Screen::print(int value)
{
    int digit;
    bool printing = false;
    
    if (value < 0)
    {
        *pCurrent++ = '-';
        value *= -1;
    }
    
    if (value > 10000 || printing)
    {
        digit = value / 10000;
        *pCurrent++ = digit + '0';
        value -= digit * 10000;
        printing = true;
    }
    if (value > 1000 || printing)
    {
        digit = value / 1000;
        *pCurrent++ = digit + '0';
        value -= digit * 1000;
        printing = true;
    }
    if (value > 100 || printing)
    {
        digit = value / 100;
        *pCurrent++ = digit + '0';
        value -= digit * 100;
        printing = true;
    }
    if (value > 10 || printing)
    {
        digit = value / 10;
        *pCurrent++ = digit + '0';
        value -= digit * 10;
        printing = true;
    }

    *pCurrent++ = value + '0';
}

void Screen::createChar(const uint8_t location, const uint8_t charmap[])
{
  lcdCreateChar(location, charmap);
}


